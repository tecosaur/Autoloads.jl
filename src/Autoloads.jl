"""
Autoloads: load packages on demand at the REPL.

Public surface: the catalog records ([`PkgNames`](@ref), [`PkgFailure`](@ref),
[`CatalogRecord`](@ref)) and the functions that extract, merge and
(de)serialise them, and the typed configuration ([`Config`](@ref),
[`PackageConfig`](@ref), [`ConfigError`](@ref)) with its parsing and queries.

Management commands, also available as the `pkg> autoloads` command group:
[`init`](@ref) sets up the global autoloads environment; [`add`](@ref),
[`remove`](@ref) and [`update`](@ref) change its packages; [`status`](@ref)
reports what autoloads. They raise [`PkgOperationFailed`](@ref) and
[`MemberMissing`](@ref).
"""
module Autoloads

public PkgNames, PkgFailure, CatalogRecord
public extract_names, merge_observation, catalog_line, parse_catalog_line

public Config, PackageConfig, ConfigError, PrecompilePolicy, Bindings
public Background, Lazy, AllBindings, UsedBindings
public parse_config, load_config, package_config, bindings_for, autoload_names

public init, add, remove, update, status, PkgOperationFailed, MemberMissing

include("records.jl")
include("catalogfile.jl")
include("config.jl")
include("envs.jl")
include("registry.jl")
include("manage.jl")

end
