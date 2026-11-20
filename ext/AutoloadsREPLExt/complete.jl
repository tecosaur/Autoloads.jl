# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Tab completion of autoloadable names, unqualified and after `P.`.

struct CompletionWrapper{P <: LineEdit.CompletionProvider} <: LineEdit.CompletionProvider
    inner::P
end

function completionsfor(reg::Registry, cat::Catalog, prefix::String, qualifier::Union{Symbol, Nothing},
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
        record = namesat(cat, id, nothing)
        record === nothing && return matches
        for names in (record.exported, record.public, record.reexported), name in names
            text = String(name)
            startswith(text, prefix) && push!(matches, text)
        end
    end
    sort!(matches)
end

"""
    completioncontext(full::String, region::Pair{Int, Int}) -> Union{Tuple{String, Union{Symbol, Nothing}}, Nothing}

The `(prefix, qualifier)` being completed at `region` of `full`, if a name
(possibly after a root `P.`), or `nothing`, as in strings, comments or `using`.
"""
function completioncontext(full::String, region::Pair{Int, Int})
    bytes = codeunits(full)
    prefix = String(bytes[region.first+1:region.second])
    before = String(bytes[1:region.first])
    line = before[something(findlast('\n', before), 0)+1:end]
    first(split(lstrip(line), !Base.is_id_char; limit = 2)) in ("using", "import") && return nothing
    Base.incomplete_tag(Base.parse_input_line(before; depwarn = false)) in (:string, :char, :cmd, :comment) &&
        return nothing
    isnameprefix = Base.isidentifier(chopprefix(prefix, "@"))
    endswith(before, '.') || return if isnameprefix; (prefix, nothing) end
    (isnameprefix || isempty(prefix)) || return nothing
    # The qualifier must be a root name, not itself a field (`A.P.`).
    head = chop(before)
    start = ncodeunits(head) + 1
    while start > 1 && Base.is_id_char(head[prevind(head, start)])
        start = prevind(head, start)
    end
    qualifier = head[start:end]
    isroot = start == 1 || head[prevind(head, start)] != '.'
    if Base.isidentifier(qualifier) && isroot; (prefix, Symbol(qualifier)) end
end

function installcompletion()
    repl = if isdefined(Base, :active_repl) Base.active_repl end
    if repl isa REPL.LineEditREPL && isdefined(repl, :interface)
        wrapcompletion!(repl)
    else
        atreplinit(wrapcompletion!)
    end
    nothing
end

LineEdit.setmodifiers!(c::CompletionWrapper, m::LineEdit.Modifiers) = LineEdit.setmodifiers!(c.inner, m)

function LineEdit.complete_line(c::CompletionWrapper, s, mod::Module; hint::Bool = false)
    result = LineEdit.complete_line(c.inner, s, mod; hint)
    session = @atomic SESSION.session
    (mod === Main && session !== nothing) || return result
    try
        withautoloadable(result, session, LineEdit.input_string(s))
    catch err
        err isa InterruptException && rethrow()
        @debug "Autoloads could not add completions" exception = (err, catch_backtrace())
        result
    end
end

# Installation and merging

function wrapcompletion!(repl)
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
    @warn "Autoloads found no `julia>` prompt to extend tab completion for; completion is unchanged"
end

function withautoloadable(result, session::Session, full::String)
    completions, region, shouldcomplete = result
    (shouldcomplete && completions isa Vector{LineEdit.NamedCompletion} && region isa Pair{Int, Int}) ||
        return result
    context = completioncontext(full, region)
    context === nothing && return result
    isbound(name) = isdefined(Main, name)
    names = completionsfor(session.registry, session.catalog, context..., isbound)
    isempty(names) && return result
    merged = unique!(c -> c.completion, [completions; LineEdit.NamedCompletion.(names)])
    sort!(merged; by = c -> c.completion), region, shouldcomplete
end
