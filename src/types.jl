struct Bindings
    macros::Vector{Symbol}
    callables::Vector{Symbol}
    variables::Vector{Symbol}
end

struct AutoDot end

Bindings(; macros::Vector{<:Union{Symbol, String}}=Symbol[],
         callables::Vector{Symbol}=Symbol[], variables=Symbol[]) =
    Bindings(Symbol.(macros), callables, variables)

struct PkgAutoloads
    pkg::Union{Symbol, Expr}
    exported::Bindings
    reexported::Bindings
    unexported::Union{Bindings, AutoDot}
    partial::Bool
end

PkgAutoloads(pkg::Union{Symbol, Expr};
             exported::Bindings = Bindings(Symbol[], Symbol[], Symbol[]),
             reexported::Bindings = Bindings(Symbol[], Symbol[], Symbol[]),
             unexported::Union{Bindings, AutoDot} = AutoDot(),
             partial::Bool = false) =
                 PkgAutoloads(pkg, exported, reexported, unexported, partial)

function PkgAutoloads(mod::Module)
    function hasparent(x::Union{DataType, Function, Method, Module}, m::Module)
        parent = parentmodule(x)
        while parent !== parentmodule(parent)
            parent === m && return true
            parent = parentmodule(parent)
        end
        parent === m
    end
    hasparent(x::Any, m::Module) = hasparent(typeof(x), m)
    hasparent(::Missing, ::Module) = false
    hasparent(u::Union, m::Module) =
        hasparent(u.a, m) && hasparent(u.b, m)
    exported = Bindings(Symbol[], Symbol[], Symbol[])
    reexported = Bindings(Symbol[], Symbol[], Symbol[])
    for symb in names(mod)
        obj = getglobal(mod, symb)
        (obj === mod || hasparent(obj, Base) || hasparent(obj, Core)) && continue
        target = if hasparent(obj, mod) exported else reexported end
        if startswith(String(symb), '@')
            push!(target.macros, symb)
        elseif obj isa Function || obj isa Type
            push!(target.callables, symb)
        else
            push!(target.variables, symb)
        end
    end
    PkgAutoloads(nameof(mod); exported, reexported)
end
