# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Tab completion: autoloadable names complete before their package loads,
# unqualified (exported names) and `P.` qualified (exported, public and
# re-exported). A pure core (`completions_for`, `completion_context`) sits
# behind `CompletionWrapper`, the one layer that touches LineEdit internals.

"""
    CompletionWrapper(inner)

A completion provider that adds autoloadable names to those of `inner`, the
Julian prompt's provider. Install with [`install_completion`](@ref).
"""
struct CompletionWrapper{P <: LineEdit.CompletionProvider} <: LineEdit.CompletionProvider
    inner::P
end

"""
    completions_for(reg, cat, prefix, qualifier, isbound) -> Vector{String}

The sorted autoloadable names starting with `prefix`. Unqualified
(`qualifier === nothing`): the names `reg` owns for which `isbound(name)`
is false. Qualified: when `qualifier` is an unbound autoload package, the
exported, public and re-exported names of its newest record in `cat`.
"""
function completions_for(reg::Registry, cat::Catalog, prefix::String, qualifier::Union{Symbol, Nothing},
                         isbound::Function)
    matches = String[]
    if qualifier === nothing
        for name in keys(reg.owners)
            text = String(name)
            startswith(text, prefix) && !isbound(name) && push!(matches, text)
        end
    else
        id = owner(reg, qualifier)
        (id === nothing || id.name != String(qualifier) || isbound(qualifier)) && return matches
        # TODO: use the autoload set's version once `Registry`/`Session` carries it.
        record = names_at(cat, id, nothing)
        record === nothing && return matches
        for names in (record.exported, record.public, record.reexported), name in names
            text = String(name)
            startswith(text, prefix) && push!(matches, text)
        end
    end
    sort!(matches)
end

"""
    completion_context(full, region) -> Union{Tuple{String, Union{Symbol, Nothing}}, Nothing}

The `(prefix, qualifier)` being completed when `region` (a byte range of
`full`, as LineEdit gives it) is a name, possibly after a root `P.`;
`nothing` for anything else, such as field access, `using`/`import`, or
inside a string, character, command or comment.
"""
function completion_context(full::String, region::Pair{Int, Int})
    bytes = codeunits(full)
    prefix = String(bytes[region.first+1:region.second])
    before = String(bytes[1:region.first])
    line = before[something(findlast('\n', before), 0)+1:end]
    occursin(r"^\s*(using|import)\b", line) && return nothing
    Base.incomplete_tag(Base.parse_input_line(before; depwarn = false)) in (:string, :char, :cmd, :comment) &&
        return nothing
    is_name_prefix = Base.isidentifier(chopprefix(prefix, "@"))
    endswith(before, '.') || return is_name_prefix ? (prefix, nothing) : nothing
    (is_name_prefix || isempty(prefix)) || return nothing
    # The qualifier must be a root name, not itself a field (`A.P.`).
    head = chop(before)
    start = ncodeunits(head) + 1
    while start > 1 && Base.is_id_char(head[prevind(head, start)])
        start = prevind(head, start)
    end
    qualifier = head[start:end]
    is_root = start == 1 || head[prevind(head, start)] != '.'
    Base.isidentifier(qualifier) && is_root ? (prefix, Symbol(qualifier)) : nothing
end

"""
    install_completion()

Wrap the Julian prompt's completion provider in a [`CompletionWrapper`](@ref):
now if a line-editing REPL is running, else from an `atreplinit` callback.
"""
function install_completion()
    repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing
    if repl isa REPL.LineEditREPL && isdefined(repl, :interface)
        wrap_completion!(repl)
    else
        atreplinit(wrap_completion!)
    end
    nothing
end

LineEdit.setmodifiers!(c::CompletionWrapper, m::LineEdit.Modifiers) = LineEdit.setmodifiers!(c.inner, m)

# Never throws, except an interrupt: on an internal error `inner`'s result stands.
function LineEdit.complete_line(c::CompletionWrapper, s, mod::Module; hint::Bool = false)
    result = LineEdit.complete_line(c.inner, s, mod; hint)
    session = @atomic SESSION.session
    (mod === Main && session !== nothing) || return result
    try
        with_autoloadable(result, session, LineEdit.input_string(s))
    catch err
        err isa InterruptException && rethrow()
        @debug "Autoloads could not add completions" exception = (err, catch_backtrace())
        result
    end
end

# ── Helpers ──

function wrap_completion!(repl)
    repl isa REPL.LineEditREPL || return
    if !(hasfield(LineEdit.Prompt, :complete) && hasmethod(LineEdit.NamedCompletion, Tuple{String}))
        @warn "Autoloads cannot extend tab completion in this REPL (unexpected `LineEdit` internals); completion is unchanged"
        return
    end
    isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
    any(mode -> mode isa LineEdit.Prompt && mode.complete isa CompletionWrapper, repl.interface.modes) && return
    for mode in repl.interface.modes
        if mode isa LineEdit.Prompt && mode.complete isa REPL.REPLCompletionProvider
            mode.complete = CompletionWrapper(mode.complete)
            return
        end
    end
    @warn "Autoloads found no Julian prompt to extend tab completion for; completion is unchanged"
end

# `inner`'s result with the autoloadable names in its context merged in.
function with_autoloadable(result, session::Session, full::String)
    completions, region, should_complete = result
    (should_complete && completions isa Vector{LineEdit.NamedCompletion} && region isa Pair{Int, Int}) ||
        return result
    context = completion_context(full, region)
    context === nothing && return result
    isbound(name) = isdefined(Main, name)
    names = completions_for(session.registry, session.catalog, context..., isbound)
    isempty(names) && return result
    merged = unique!(c -> c.completion, [completions; LineEdit.NamedCompletion.(names)])
    sort!(merged; by = c -> c.completion), region, should_complete
end
