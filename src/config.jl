# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Configuration: the merged `[preferences.Autoloads]` dict parsed into typed
# settings. `parse_config` is pure; `load_config` is the only preferences read.

"When package precompilation happens."
@enum PrecompilePolicy Background Lazy

"Which of a package's bindings are made available: every one, or those used."
@enum Bindings AllBindings UsedBindings

"""
    PackageConfig(skip, only, bindings)

Per-package overrides. `only === nothing` means no restriction and
`bindings === nothing` inherits [`Config`](@ref)'s setting.
"""
struct PackageConfig
    skip::Set{Symbol}
    only::Union{Set{Symbol}, Nothing}
    bindings::Union{Bindings, Nothing}
end

"""
    Config(stdlib, project, policy, bindings, log, packages)

Typed autoload settings. `project === nothing` means every direct dependency
of the project; an empty set means none. `log` is whether each autoload is
announced. `packages` maps package names to their [`PackageConfig`](@ref).
"""
struct Config
    stdlib::Bool
    project::Union{Set{String}, Nothing}
    policy::PrecompilePolicy
    bindings::Bindings
    log::Bool
    packages::Dict{String, PackageConfig}
end

"""
    ConfigError(keypath, expected, found)

A preference at `keypath` (e.g. `["packages", "DataFrames", "skip"]`) was
not `expected`; `found` is the offending value.
"""
struct ConfigError <: Exception
    keypath::Vector{String}
    expected::String
    found::Any
end

function Base.showerror(io::IO, e::ConfigError)
    print(io, "Autoloads preference `", join(e.keypath, "."), "` should be ", e.expected,
          ", found ", repr(e.found), " (", typeof(e.found), "). ",
          "Fix [preferences.Autoloads] in the global environment's Project.toml ",
          "or LocalPreferences.toml (or the active project's, if it overrides it).")
end

const TOP_LEVEL_KEYS = ["stdlib", "project", "precompile", "bindings", "log", "packages"]
const PACKAGE_KEYS = ["skip", "only", "bindings"]
const POLICY_NAMES = Dict("background" => Background, "lazy" => Lazy)
const BINDINGS_NAMES = Dict("all" => AllBindings, "used" => UsedBindings)

"""
    parse_config(prefs::AbstractDict) -> Config

Parse merged preferences (as parsed TOML) into a [`Config`](@ref). Missing
keys take their defaults: `stdlib = true`, `project = true`,
`precompile = "background"`, `bindings = "all"`, `log = false`.

Throws [`ConfigError`](@ref) for unknown keys or values of the wrong shape.
"""
function parse_config(prefs::AbstractDict)
    prefs = as_table(prefs)
    check_keys(prefs, TOP_LEVEL_KEYS, String[])
    Config(
        parse_bool(prefs, "stdlib", true),
        parse_project(get(prefs, "project", true)),
        parse_choice(prefs, "precompile", POLICY_NAMES, Background),
        parse_choice(prefs, "bindings", BINDINGS_NAMES, AllBindings),
        parse_bool(prefs, "log", false),
        parse_packages(get(prefs, "packages", Dict{String, Any}())))
end

"""
    load_config() -> Config

Read the merged `[preferences.Autoloads]` and parse it with [`parse_config`](@ref).
"""
load_config() = parse_config(Base.get_preferences(Base.PkgId(@__MODULE__).uuid))

"""
    package_config(cfg::Config, name::AbstractString) -> PackageConfig

The overrides for package `name`, or empty overrides if none are configured.
"""
package_config(cfg::Config, name::AbstractString) =
    get(cfg.packages, String(name), PackageConfig(Set{Symbol}(), nothing, nothing))

"""
    bindings_for(cfg::Config, name::AbstractString) -> Bindings

The bindings setting for package `name`: its override, else the global one.
"""
bindings_for(cfg::Config, name::AbstractString) =
    something(package_config(cfg, name).bindings, cfg.bindings)

"""
    autoload_names(record::PkgNames, config::PackageConfig) -> Set{Symbol}

Names to autoload unqualified: exported and reexported names, restricted to
`only` if set, minus `skip`. The module's own name is always kept;
public-only names are never included.
"""
function autoload_names(record::PkgNames, config::PackageConfig)
    names = record.exported ∪ record.reexported
    config.only === nothing || intersect!(names, config.only)
    setdiff!(names, config.skip)
    push!(names, Symbol(last(split(record.id.name, '.'))))
end

# Settings are untyped: tables are narrowed to TOML's own type, and values taken
# unspecialised, so that calls resolve statically and their code is cached.
as_table(@nospecialize(table::AbstractDict)) =
    table isa Dict{String, Any} ? table : Dict{String, Any}(string(key) => value for (key, value) in table)

function check_keys(dict::Dict{String, Any}, valid::Vector{String}, keypath::Vector{String})
    for key in keys(dict)
        key in valid || throw(ConfigError([keypath; string(key)],
            "one of " * join(map(k -> "`$k`", valid), ", "), key))
    end
end

function parse_bool(dict::Dict{String, Any}, key::String, default::Bool)
    value = get(dict, key, default)
    value isa Bool || throw(ConfigError([key], "true or false", value))
    value
end

function parse_choice(dict::Dict{String, Any}, key::String, choices::Dict, default; keypath::Vector{String} = String[])
    haskey(dict, key) || return default
    value = dict[key]
    (value isa AbstractString && haskey(choices, value)) ||
        throw(ConfigError([keypath; key], join(map(repr, sort!(collect(keys(choices)))), " or "), value))
    choices[value]
end

function parse_names(@nospecialize(value), keypath::Vector{String})
    is_valid = value isa AbstractVector
    names = String[]
    for name in (is_valid ? value : ())
        name isa AbstractString ? push!(names, name) : (is_valid = false)
    end
    is_valid || throw(ConfigError(keypath, "a list of names", value))
    names
end

function parse_project(@nospecialize(value))
    value === true && return nothing
    value === false && return Set{String}()
    Set(parse_names(value, ["project"]))
end

function parse_packages(@nospecialize(value))
    value isa AbstractDict || throw(ConfigError(["packages"], "a table of package settings", value))
    packages = Dict{String, PackageConfig}()
    for (name, settings) in as_table(value)
        packages[name] = parse_package(settings, ["packages", name])
    end
    packages
end

function parse_package(@nospecialize(settings), keypath::Vector{String})
    settings isa AbstractDict || throw(ConfigError(keypath, "a table with keys `skip`, `only`, `bindings`", settings))
    table = as_table(settings)
    check_keys(table, PACKAGE_KEYS, keypath)
    names(key) = Set{Symbol}(map(Symbol, parse_names(table[key], [keypath; key])))
    skip = if haskey(table, "skip") names("skip") else Set{Symbol}() end
    only = if haskey(table, "only") names("only") else nothing end
    PackageConfig(skip, only, parse_choice(table, "bindings", BINDINGS_NAMES, nothing; keypath))
end
