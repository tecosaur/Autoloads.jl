# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Project, manifest and state-directory readers, and subprocess helpers.

const BUILTIN_MODULES = (Base.Threads,)

"""
    ENV_CHANGED

Called, when set, by `notify_env_change`.
"""
const ENV_CHANGED = Ref{Any}(nothing)

"""
    ManifestGraph(versions, deps)

A manifest's package `versions` (`nothing` for stdlibs) and `deps`, by UUID.
"""
struct ManifestGraph
    versions::Dict{Base.UUID, Union{VersionNumber, Nothing}}
    deps::Dict{Base.UUID, Vector{Base.UUID}}
end

ManifestGraph() = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(), Dict{Base.UUID, Vector{Base.UUID}}())

global_env_dir() = dirname(Base.load_path_expand("@v#.#"))

member_dir(global_dir = global_env_dir()) = joinpath(global_dir, "autoloads")

"""
    state_dir(version = VERSION) -> String

Where changes deferred to Julia `version`'s minor are kept.
"""
state_dir(version::VersionNumber = VERSION) = joinpath(state_root(), "v$(version.major).$(version.minor)")

"""
    state_root() -> String

`julia/autoloads` in the user's state directory, found as BaseDirs.jl does:
`XDG_STATE_HOME` if absolute, else `~/.local/state`, `~/Library/Application
Support` on macOS, or `LOCALAPPDATA` on Windows.
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

catalog_path() = joinpath(state_root(), "catalog")

function project_deps(project_file::AbstractString)
    isfile(project_file) || return Base.PkgId[]
    deps = get(Base.parsed_toml(project_file), "deps", Dict{String, Any}())::Dict{String, Any}
    [Base.PkgId(Base.UUID(uuid::String), name) for (name, uuid) in deps]
end

"""
    manifest_graph(project_file) -> ManifestGraph

The graph of the manifest Base uses for `project_file` (for a workspace member,
the root's); empty without one.
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

The direct deps and manifest graph of `project_file`, empty without one. A
package project counts among its own deps.
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

builtin_records() =
    [extract_names(m, Base.PkgId(nothing, "Base." * string(nameof(m)))) for m in BUILTIN_MODULES]

"""
    run_julia(args::Cmd; project, env = (), nice = false, detach = false, output = stdout) -> Base.Process

Start Julia running `args`, with this session's flags and no startup or history
file, without waiting. `nice` lowers its priority where possible.
"""
run_julia(args::Cmd; output = stdout, options...) =
    run(pipeline(julia_command(args; options...); stdout = output, stderr = output); wait = false)

"""
    julia_command(args::Cmd; project, env = (), nice = false, detach = false) -> Cmd

The command `run_julia` runs, with `env` added to the current `ENV`.
"""
function julia_command(args::Cmd; project, env = (), nice::Bool = false, detach::Bool = false)
    niceness = if nice && Sys.which("nice") !== nothing; `nice -n 10` else `` end
    project_flag = if project === nothing; `` else `--project=$project` end
    cmd = addenv(`$niceness $(Base.julia_cmd()) --startup-file=no --history-file=no $project_flag $args`, env...)
    if detach Base.detach(cmd) else cmd end
end

notify_env_change() = ENV_CHANGED[] === nothing || ENV_CHANGED[]()
