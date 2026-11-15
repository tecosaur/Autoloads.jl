"""
Autoloads: load packages on demand at the REPL.

Public surface: the catalog records ([`PkgNames`](@ref), [`PkgFailure`](@ref),
[`CatalogRecord`](@ref)) and the functions that extract, merge and
(de)serialise them, and the typed configuration ([`Config`](@ref),
[`PackageConfig`](@ref), [`ConfigError`](@ref)) with its parsing and queries.
"""
module Autoloads

public PkgNames, PkgFailure, CatalogRecord
public extract_names, merge_observation, catalog_line, parse_catalog_line

public Config, PackageConfig, ConfigError, PrecompilePolicy, Bindings
public Background, Lazy, AllBindings, UsedBindings
public parse_config, load_config, package_config, bindings_for, autoload_names

include("records.jl")
include("catalogfile.jl")
include("config.jl")
include("envs.jl")
include("registry.jl")

end
