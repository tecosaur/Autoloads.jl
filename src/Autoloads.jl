module Autoloads

using TOML
using REPL
using Serialization

using BaseDirs

include("types.jl")

const AUTOLOADS =
    (sources = Dict{Symbol, PkgAutoloads}(),
     pkgs = Dict{Symbol, Expr}(),
     exported = (
         macros = Dict{Symbol, Symbol}(),
         callables = Dict{Symbol, Symbol}(),
         variables = Dict{Symbol, Symbol}()),
     reexports = Set{Symbol}(),
     bindings = (
         macros = Dict{Symbol, Set{Symbol}}(),
         callables = Dict{Symbol, Set{Symbol}}(),
         variables = Dict{Symbol, Set{Symbol}}()),
     ondotaccess = Set{Symbol}(),
     loaded = Set{Symbol}(),
     partloaded = Dict{Symbol, Set{Symbol}}())

function __init__()
    if isinteractive() @async @eval begin
        pushfirst!(REPL.repl_ast_transforms, repl_scan_autoloads!)
    end end
end

end
