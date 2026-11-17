# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Input scanning: a cheap syntactic pass decides which REPL statements could
# involve an autoload package, then lowering resolves which globals a
# candidate statement actually references.

# Lowered calls `f(mod, name, ...)` that bind `name` in `mod`, across 1.12-1.14.
const BINDING_CALLS = (:declare_global, :declare_const, :setglobal!, :define_method)

# The macro of `REPL` that `REPL.helpmode` hands the queried expression to.
const HELP_MACRO = QuoteNode(Symbol("@repl"))

"""
    map_statements(f, ex) -> Any

Rebuild `ex` with each statement replaced by `f(statement)`, recursing through
`:toplevel` as `REPL.softscope` does and passing `LineNumberNode`s through.
A statement is the unit the REPL evaluates: for softscoped input, the
`Expr(:block, Expr(:softscope, true), stmt)` wrapper (1.14 adds line
nodes); otherwise the bare expression. Return the statement itself from `f`
to leave it unchanged.

# Example
```julia
map_statements(st -> :(println(\$st)), Meta.parse("a; b")) # Expr(:toplevel, :(println(a)), :(println(b)))
```
"""
function map_statements(f, ex)
    ex isa LineNumberNode && return ex
    Meta.isexpr(ex, :toplevel) || return f(ex)
    Expr(:toplevel, Any[map_statements(f, arg) for arg in ex.args]...)
end

"""
    is_candidate_statement(reg, stmt, member_only) -> Bool

Whether `stmt` syntactically mentions, outside quotes (`\$` interpolations
count), a name or macro name that [`is_candidate`](@ref) in `reg`, or a
`using`/`import` whose root module satisfies `member_only(::Symbol)`.
"""
function is_candidate_statement(reg::Registry, stmt, member_only::Function)
    any_unquoted(stmt) do node
        if node isa Symbol is_candidate(reg, node) else is_member_only_import(node, member_only) end
    end
end

"""
    has_member_only_using(stmt, member_only) -> Bool

Whether `stmt` holds, outside quotes, a `using`/`import` whose root module
satisfies `member_only(::Symbol)`. Relative imports (`using .M`) never do.
"""
has_member_only_using(stmt, member_only::Function) = any_unquoted(node -> is_member_only_import(node, member_only), stmt)

"""
    statement_macros(stmt) -> Vector{Symbol}

The macros `stmt` invokes outside quotes, in order of appearance without
repeats: `Symbol("@m")` for an unqualified `@m`, the root module `A` for
`A.B.@m`.
"""
function statement_macros(stmt)
    macros = Symbol[]
    any_unquoted(stmt) do node
        if Meta.isexpr(node, :macrocall)
            root = dotted_root(node.args[1])
            root === nothing || push!(macros, root)
        end
        false
    end
    unique!(macros)
end

"""
    undefined_globals(stmt, mod) -> Vector{Symbol}

The globals of `mod` that lowering `stmt` in `mod` reads while undefined,
in order of first appearance. Names the statement itself binds (assignment,
method, `global` and `const` targets) and compiler-generated `#` names are
excluded. Lowering failures, such as an undefined macro, give `Symbol[]`:
such a statement references nothing resolvable yet.
"""
function undefined_globals(stmt, mod::Module)
    lowered = try
        Meta.lower(mod, stmt)
    catch err
        err isa InterruptException && rethrow()
        return Symbol[]
    end
    referenced, bound = Symbol[], Set{Symbol}()
    # A bare name lowers to itself.
    if lowered isa Symbol push!(referenced, lowered) else collect_globals!(referenced, bound, lowered, mod) end
    filter(name -> name ∉ bound && !startswith(String(name), '#') && !isdefined(mod, name), unique!(referenced))
end

"""
    help_query_names(stmt) -> Union{Vector{Symbol}, Nothing}

The names and macro names outside quotes in the expression that help-mode
input `stmt` (as built by `REPL.helpmode`) asks about, in order of
appearance without repeats: `help?> A.f(x)` gives `[:A, :x]`. `nothing` when
`stmt` is not help-mode input. Syntactic: help expands no macro of the query.
"""
function help_query_names(stmt)
    names = Symbol[]
    is_help = any_unquoted(stmt) do node
        Meta.isexpr(node, :macrocall) && length(node.args) >= 4 || return false
        callee = node.args[1]
        # Not `==`: comparing expressions compiles on first use.
        Meta.isexpr(callee, :., 2) && callee.args[1] === REPL && callee.args[2] === HELP_MACRO || return false
        any_unquoted(name -> (name isa Symbol && push!(names, name); false), node.args[4])
        true
    end
    if is_help unique!(names) end
end

# ── Helpers ──

"Whether `pred` holds for any node of `ex` outside quotes; stops at the first."
function any_unquoted(pred, ex, quote_depth::Int = 0)
    quote_depth == 0 && pred(ex) && return true
    ex isa Expr || return false
    inner = if ex.head === :quote quote_depth + 1 elseif ex.head === :$ max(quote_depth - 1, 0) else quote_depth end
    any(arg -> any_unquoted(pred, arg, inner), ex.args)
end

"Whether `node` is a non-relative `using`/`import` of a module satisfying `member_only`."
function is_member_only_import(node, member_only::Function)
    Meta.isexpr(node, (:using, :import)) || return false
    any(node.args) do path
        Meta.isexpr(path, (:(:), :as)) && (path = path.args[1])
        root = dotted_root(path)
        root isa Symbol && root !== :. && member_only(root)
    end
end

"The leftmost symbol of a dotted path `A.B.c`, or `nothing`."
function dotted_root(path)
    path isa Symbol && return path
    if Meta.isexpr(path, :.) dotted_root(path.args[1]) end
end

"Record into `referenced` every `GlobalRef` into `mod` within lowered `x`, and into `bound` the names it binds."
function collect_globals!(referenced::Vector{Symbol}, bound::Set{Symbol}, x, mod::Module)
    if x isa GlobalRef
        x.mod === mod && push!(referenced, x.name)
    elseif x isa Core.CodeInfo
        foreach(st -> collect_globals!(referenced, bound, st, mod), x.code)
    elseif x isa Expr
        for target in binding_targets(x, mod)
            name = if target isa GlobalRef target.name elseif target isa QuoteNode target.value else target end
            name isa Symbol && push!(bound, name)
        end
        foreach(arg -> collect_globals!(referenced, bound, arg, mod), x.args)
    end
end

"The operands of lowered `ex` naming globals it binds in `mod`."
function binding_targets(ex::Expr, mod::Module)
    ex.head === :global && return ex.args
    ex.head in (:method, :globaldecl, :const, :(=)) && return ex.args[1:1]
    callee = if Meta.isexpr(ex, :call) ex.args[1] end
    is_binding_call = callee isa GlobalRef && callee.name in BINDING_CALLS && length(ex.args) >= 3 && ex.args[2] === mod
    if is_binding_call ex.args[3:3] else () end
end
