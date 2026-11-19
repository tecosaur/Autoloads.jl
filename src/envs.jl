# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Environments: the global autoloads workspace member, project and manifest
# readers, the stdlib list, built-in records and subprocess helpers.

const BUILTIN_MODULES = (Base.Threads,)

"Called by [`notify_env_change`](@ref); set by whoever wants to react."
const ENV_CHANGED = Ref{Any}(nothing)

"""
    ManifestGraph(versions, deps)

The packages of a manifest: `versions` maps each UUID to its version
(`nothing` for stdlibs) and `deps` to the UUIDs it depends on.
"""
struct ManifestGraph
    versions::Dict{Base.UUID, Union{VersionNumber, Nothing}}
    deps::Dict{Base.UUID, Vector{Base.UUID}}
end

ManifestGraph() = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(), Dict{Base.UUID, Vector{Base.UUID}}())

"The directory of this Julia version's global environment (`@v#.#`)."
global_env_dir() = dirname(Base.load_path_expand("@v#.#"))

"""
    member_dir(global_dir = global_env_dir())

The `autoloads` workspace member of the global environment in `global_dir`.
"""
member_dir(global_dir = global_env_dir()) = joinpath(global_dir, "autoloads")

"""
    state_dir(version = VERSION) -> String

The Autoloads state of Julia `version`'s minor (the changes deferred to it):
`v#.#` in [`state_root`](@ref).
"""
state_dir(version::VersionNumber = VERSION) = joinpath(state_root(), "v$(version.major).$(version.minor)")

"""
    state_root() -> String

The Autoloads state of every Julia version: `julia/autoloads` in the user's
state directory, as BaseDirs.jl's `User.state` finds it: `XDG_STATE_HOME`
when it is an absolute path, otherwise `~/.local/state`,
`~/Library/Application Support` on macOS, or `LOCALAPPDATA` on Windows.
"""
function state_root()
    xdg_state = get(ENV, "XDG_STATE_HOME", "")
    state = if isabspath(xdg_state)
        xdg_state
    elseif Sys.iswindows()
        get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        joinpath(homedir(), "Library", "Application Support")
    else
        joinpath(homedir(), ".local", "state")
    end
    joinpath(state, "julia", "autoloads")
end

"The package catalog file, shared by every Julia version."
catalog_path() = joinpath(state_root(), "catalog")

"""
    project_deps(project_file) -> Vector{Base.PkgId}

The `[deps]` of `project_file`; empty when the file does not exist.
"""
function project_deps(project_file::AbstractString)
    isfile(project_file) || return Base.PkgId[]
    deps = get(Base.parsed_toml(project_file), "deps", Dict{String, Any}())::Dict{String, Any}
    [Base.PkgId(Base.UUID(uuid::String), name) for (name, uuid) in deps]
end

"""
    manifest_graph(project_file) -> ManifestGraph

The graph of the manifest Base would use for `project_file` (a workspace
member gets the root's; versioned manifest names are honoured). Empty when
there is no manifest.
"""
function manifest_graph(project_file::AbstractString)
    graph = ManifestGraph()
    manifest = if isfile(project_file) Base.project_file_manifest_path(project_file) end
    manifest === nothing && return graph
    entries = get(Base.parsed_toml(manifest), "deps", Dict{String, Any}())::Dict{String, Any}
    uuid_of = Dict{String, Base.UUID}(name => Base.UUID(first(infos::Vector{Any})["uuid"]::String)
                                      for (name, infos) in entries)
    for infos in values(entries), info in infos::Vector{Any}
        info = info::Dict{String, Any}
        uuid = Base.UUID(info["uuid"]::String)
        graph.versions[uuid] = if haskey(info, "version") VersionNumber(info["version"]::String) end
        graph.deps[uuid] = dependency_uuids(get(info, "deps", String[]), uuid_of)
    end
    graph
end

# `deps` is a list of names, or a name => UUID table when names are ambiguous.
# Names absent from the manifest are skipped, as Base does when resolving them.
function dependency_uuids(@nospecialize(deps), uuid_of::Dict{String, Base.UUID})
    deps isa AbstractDict && return Base.UUID[Base.UUID(uuid::String) for uuid in values(deps)]
    uuids = Base.UUID[]
    for name in deps
        haskey(uuid_of, name) && push!(uuids, uuid_of[name])
    end
    uuids
end

"""
    environment(project_file) -> (; deps::Vector{Base.PkgId}, graph::ManifestGraph)

The direct deps and manifest graph of `project_file`; empty for `nothing` or a
missing file. A package project (one with a `name` and `uuid`) counts among
its own deps, at its own `version`.
"""
function environment(project_file::Union{String, Nothing})
    (project_file === nothing || !isfile(project_file)) && return (deps = Base.PkgId[], graph = ManifestGraph())
    deps, graph = project_deps(project_file), manifest_graph(project_file)
    project = Base.parsed_toml(project_file)
    if haskey(project, "name") && haskey(project, "uuid")
        uuid = Base.UUID(project["uuid"]::String)
        graph.versions[uuid] = if haskey(project, "version") VersionNumber(project["version"]::String) end
        push!(deps, Base.PkgId(uuid, project["name"]::String))
    end
    (; deps, graph)
end

"""
    dependency_closure(graph, uuid) -> Set{Base.UUID}

`uuid` and everything it transitively depends on.
"""
function dependency_closure(graph::ManifestGraph, uuid::Base.UUID)
    closure = Set([uuid])
    pending = [uuid]
    while !isempty(pending)
        for dep in get(graph.deps, pop!(pending), Base.UUID[])
            dep in closure || (push!(closure, dep); push!(pending, dep))
        end
    end
    closure
end

"""
    stdlib_ids() -> Vector{Base.PkgId}

The standard libraries in `Sys.STDLIB`, excluding JLL packages.
"""
function stdlib_ids()
    ids = Base.PkgId[]
    for name in readdir(Sys.STDLIB)
        endswith(name, "_jll") && continue
        project = joinpath(Sys.STDLIB, name, "Project.toml")
        isfile(project) || continue
        uuid = get(Base.parsed_toml(project), "uuid", nothing)
        uuid === nothing || push!(ids, Base.PkgId(Base.UUID(uuid), name))
    end
    ids
end

"Records for the submodules of `Base` that are autoloadable."
builtin_records() =
    [extract_names(m, Base.PkgId(nothing, "Base." * string(nameof(m)))) for m in BUILTIN_MODULES]

"""
    run_julia(args::Cmd; project, env = (), nice = false, detach = false, output = stdout) -> Base.Process

Start a Julia subprocess running `args`, with the current session's flags and
no startup or history file. `project` is the `--project` to use, or
`nothing` for the default. `env` is a collection of `name => value` pairs;
`nice` lowers its priority where `nice` is available. Does not wait for it.
"""
run_julia(args::Cmd; output = stdout, options...) =
    run(pipeline(julia_command(args; options...); stdout = output, stderr = output); wait = false)

"""
    julia_command(args::Cmd; project, env = (), nice = false, detach = false) -> Cmd

The command [`run_julia`](@ref) runs, with `env` added to a copy of `ENV`
taken now, so running it later still sees the current environment.
"""
function julia_command(args::Cmd; project, env = (), nice::Bool = false, detach::Bool = false)
    niceness = if nice && Sys.which("nice") !== nothing; `nice -n 10` else `` end
    project_flag = if project === nothing; `` else `--project=$project` end
    cmd = addenv(`$niceness $(Base.julia_cmd()) --startup-file=no --history-file=no $project_flag $args`, env...)
    if detach Base.detach(cmd) else cmd end
end

"Tell whoever registered in [`ENV_CHANGED`](@ref) that the environment changed."
notify_env_change() = ENV_CHANGED[] === nothing || ENV_CHANGED[]()
