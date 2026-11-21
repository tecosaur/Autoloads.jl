# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# `[preferences.Autoloads]` parsed into typed settings.

@enum PrecompilePolicy Background Lazy

@enum Bindings AllBindings UsedBindings

struct PackageConfig
    skip::Set{Symbol}
    only::Union{Set{Symbol}, Nothing}
    bindings::Union{Bindings, Nothing}
end

struct Config
    stdlib::Bool
    project::Union{Set{String}, Nothing}
    policy::PrecompilePolicy
    bindings::Bindings
    log::Bool
    uphook::Bool
    packages::Dict{String, PackageConfig}
end

"""
    ConfigError(keypath, expected, found)

The preference at `keypath` should have been `expected`, but was `found`.
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

const TOP_LEVEL_KEYS = ["stdlib", "project", "precompile", "bindings", "log", "up_hook", "packages"]
const PACKAGE_KEYS = ["skip", "only", "bindings"]
const POLICY_NAMES = Dict("background" => Background, "lazy" => Lazy)
const BINDINGS_NAMES = Dict("all" => AllBindings, "used" => UsedBindings)

function parseconfig(prefs::AbstractDict)
    prefs = astable(prefs)
    checkkeys(prefs, TOP_LEVEL_KEYS, String[])
    Config(
        parsebool(prefs, "stdlib", true),
        parseproject(get(prefs, "project", true)),
        parsechoice(prefs, "precompile", POLICY_NAMES, Background),
        parsechoice(prefs, "bindings", BINDINGS_NAMES, AllBindings),
        parsebool(prefs, "log", false),
        parsebool(prefs, "up_hook", true),
        parsepackages(get(prefs, "packages", Dict{String, Any}())))
end

loadconfig() = parseconfig(Base.get_preferences(Base.PkgId(@__MODULE__).uuid))

packageconfig(cfg::Config, name::AbstractString) =
    get(cfg.packages, String(name), PackageConfig(Set{Symbol}(), nothing, nothing))

"""
    autoloadnames(record::PkgNames, config::PackageConfig) -> Set{Symbol}

The names to autoload unqualified: exported and re-exported names, narrowed by
`config`, and the module's own name.
"""
function autoloadnames(record::PkgNames, config::PackageConfig)
    names = record.exported ∪ record.reexported
    config.only === nothing || intersect!(names, config.only)
    setdiff!(names, config.skip)
    push!(names, Symbol(last(split(record.id.name, '.'))))
end

# Settings are narrowed to TOML's own types, and otherwise taken unspecialised,
# so that parsing them resolves statically and its code is cached.
astable(@nospecialize(table::AbstractDict)) =
    if table isa Dict{String, Any} table else Dict{String, Any}(string(k) => v for (k, v) in table) end

function checkkeys(dict::Dict{String, Any}, valid::Vector{String}, keypath::Vector{String})
    for key in keys(dict)
        key in valid || throw(ConfigError(push!(copy(keypath), string(key)),
            "one of " * join(map(k -> "`$k`", valid), ", "), key))
    end
end

function parsebool(dict::Dict{String, Any}, key::String, default::Bool)
    value = get(dict, key, default)
    value isa Bool || throw(ConfigError([key], "true or false", value))
    value
end

function parsechoice(dict::Dict{String, Any}, key::String, choices::Dict, default, keypath::Vector{String} = String[])
    haskey(dict, key) || return default
    value = dict[key]
    (value isa AbstractString && haskey(choices, value)) ||
        throw(ConfigError(push!(copy(keypath), key), join(map(repr, sort!(collect(keys(choices)))), " or "), value))
    choices[value]
end

function parsenames(@nospecialize(value), keypath::Vector{String})
    value isa Vector{String} && return value
    value isa AbstractVector && all(name -> name isa AbstractString, value) ||
        throw(ConfigError(keypath, "a list of names", value))
    String[name for name in value]
end

function parseproject(@nospecialize(value))
    value === true && return nothing
    value === false && return Set{String}()
    Set(parsenames(value, ["project"]))
end

function parsepackages(@nospecialize(value))
    value isa AbstractDict || throw(ConfigError(["packages"], "a table of package settings", value))
    Dict{String, PackageConfig}(name => parsepackage(settings, ["packages", name]) for (name, settings) in astable(value))
end

function parsepackage(@nospecialize(settings), keypath::Vector{String})
    settings isa AbstractDict || throw(ConfigError(keypath, "a table with keys `skip`, `only`, `bindings`", settings))
    table = astable(settings)
    checkkeys(table, PACKAGE_KEYS, keypath)
    names(key) = Set{Symbol}(map(Symbol, parsenames(table[key], push!(copy(keypath), key))))
    skip = if haskey(table, "skip") names("skip") else Set{Symbol}() end
    only = if haskey(table, "only") names("only") else nothing end
    PackageConfig(skip, only, parsechoice(table, "bindings", BINDINGS_NAMES, nothing, keypath))
end
