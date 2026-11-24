# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Input scanning: a syntactic pass picks candidate statements, and lowering finds
# the globals they read.

# Lowered calls `f(mod, name, ...)` that bind `name` in `mod`, across 1.12-1.14.
const BINDING_CALLS = (:declare_global, :declare_const, :setglobal!, :define_method)

# The macro of `REPL` that `REPL.helpmode` hands the queried expression to.
const HELP_MACRO = QuoteNode(Symbol("@repl"))

"""
    mapstatements(f, ex) -> Any

Rebuild `ex` with each statement, what the REPL evaluates as one, replaced by
`f(statement)`.
"""
function mapstatements(f, @nospecialize(ex))
    ex isa LineNumberNode && return ex
    Meta.isexpr(ex, :toplevel) || return f(ex)
    Expr(:toplevel, Any[mapstatements(f, arg) for arg in ex.args]...)
end

function iscandidatestatement(reg::Registry, stmt, memberonly::Function)
    anyunquoted(stmt) do node
        if node isa Symbol iscandidate(reg, node) else ismemberonlyimport(node, memberonly) end
    end
end

"""
    statementmacros(stmt) -> Vector{Symbol}

The macros `stmt` invokes outside quotes, each as `Symbol("@m")`, or for
`A.B.@m` its root `A`.
"""
function statementmacros(stmt)
    macros = Symbol[]
    anyunquoted(stmt) do node
        if Meta.isexpr(node, :macrocall)
            root = dottedroot(node.args[1])
            root === nothing || push!(macros, root)
        end
        false
    end
    unique!(macros)
end

"""
    undefinedglobals(stmt, mod::Module) -> Vector{Symbol}

The undefined globals of `mod` that `stmt` reads once lowered, other than those
it binds. Empty if lowering fails.
"""
function undefinedglobals(stmt, mod::Module)
    lowered = try
        Meta.lower(mod, stmt)
    catch err
        isinterrupt(err) && rethrow()
        return Symbol[]
    end
    referenced, bound = Symbol[], Set{Symbol}()
    # A bare name lowers to itself.
    if lowered isa Symbol push!(referenced, lowered) else collectglobals!(referenced, bound, lowered, mod) end
    filter(name -> name ∉ bound && !startswith(String(name), '#') && !isdefined(mod, name), unique!(referenced))
end

"""
    helpquerynames(stmt) -> Union{Vector{Symbol}, Nothing}

The names help-mode input `stmt` asks about (`help?> A.f(x)` gives `[:A, :x]`),
or `nothing` if `stmt` is not help input.
"""
function helpquerynames(stmt)
    names = Symbol[]
    ishelp = anyunquoted(stmt) do node
        Meta.isexpr(node, :macrocall) && length(node.args) >= 4 || return false
        callee = node.args[1]
        # Not `==`: comparing expressions compiles on first use.
        Meta.isexpr(callee, :., 2) && callee.args[1] === REPL && callee.args[2] === HELP_MACRO || return false
        anyunquoted(name -> (name isa Symbol && push!(names, name); false), node.args[4])
        true
    end
    if ishelp unique!(names) end
end

# Expression walking

function anyunquoted(pred, ex, quotedepth::Int = 0)
    quotedepth == 0 && pred(ex) && return true
    ex isa Expr || return false
    inner = if ex.head === :quote quotedepth + 1 elseif ex.head === :$ max(quotedepth - 1, 0) else quotedepth end
    any(arg -> anyunquoted(pred, arg, inner), ex.args)
end

ismemberonlyimport(node, memberonly::Function) =
    Meta.isexpr(node, (:using, :import)) && any(memberonly, importroots(node))

function importroots(ex::Expr)
    roots = Symbol[]
    for path in ex.args
        root = dottedroot(if Meta.isexpr(path, (:(:), :as)) path.args[1] else path end)
        root isa Symbol && root !== :. && push!(roots, root)
    end
    roots
end

function dottedroot(path)
    path isa Symbol && return path
    if Meta.isexpr(path, :.) dottedroot(path.args[1]) end
end

function collectglobals!(referenced::Vector{Symbol}, bound::Set{Symbol}, x, mod::Module)
    function bindingtargets(ex::Expr)
        ex.head === :global && return ex.args
        ex.head in (:method, :globaldecl, :const, :(=)) && return ex.args[1:1]
        callee = if Meta.isexpr(ex, :call) ex.args[1] end
        isbindingcall = callee isa GlobalRef && callee.name in BINDING_CALLS && length(ex.args) >= 3 && ex.args[2] === mod
        if isbindingcall ex.args[3:3] else () end
    end
    if x isa GlobalRef
        x.mod === mod && push!(referenced, x.name)
    elseif x isa Core.CodeInfo
        foreach(st -> collectglobals!(referenced, bound, st, mod), x.code)
    elseif x isa Expr
        for target in bindingtargets(x)
            name = if target isa GlobalRef target.name elseif target isa QuoteNode target.value else target end
            name isa Symbol && push!(bound, name)
        end
        foreach(arg -> collectglobals!(referenced, bound, arg, mod), x.args)
    end
end
