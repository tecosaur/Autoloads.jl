# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Readers of projects, manifests, the state directory, and what Julia ships.

const BUILTIN_MODULES = (Base.Threads,)

struct ManifestGraph
    versions::Dict{Base.UUID, Union{VersionNumber, Nothing}}  # `nothing` for a stdlib
    deps::Dict{Base.UUID, Vector{Base.UUID}}
end

ManifestGraph() = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(), Dict{Base.UUID, Vector{Base.UUID}}())

const Environment = @NamedTuple{deps::Vector{Base.PkgId}, graph::ManifestGraph}

globalenvdir() = dirname(Base.load_path_expand("@v#.#")::String)

memberdir(globaldir = globalenvdir()) = joinpath(globaldir, "autoloads")

statedir(version::VersionNumber = VERSION) = joinpath(stateroot(), "v$(version.major).$(version.minor)")

"""
    stateroot() -> String

`julia/autoloads` in the user's state directory, found as BaseDirs.jl does:
`XDG_STATE_HOME` if absolute, else `~/.local/state`, `~/Library/Application
Support` on macOS, or `LOCALAPPDATA` on Windows.
"""
function stateroot()
    xdgstate = get(ENV, "XDG_STATE_HOME", "")
    state = if isabspath(xdgstate)
        xdgstate
    elseif Sys.iswindows()
        get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        joinpath(homedir(), "Library", "Application Support")
    else
        joinpath(homedir(), ".local", "state")
    end
    joinpath(state, "julia", "autoloads")
end

catalogpath() = joinpath(stateroot(), "catalog")

function projectdeps(projectfile::AbstractString)
    isfile(projectfile) || return Base.PkgId[]
    deps = get(Base.parsed_toml(projectfile), "deps", Dict{String, Any}())::Dict{String, Any}
    [Base.PkgId(Base.UUID(uuid::String), name) for (name, uuid) in deps]
end

"""
    manifestgraph(projectfile::AbstractString) -> ManifestGraph

The graph of the manifest Base uses for `projectfile` (for a workspace member,
the root's); empty without one.
"""
function manifestgraph(projectfile::AbstractString)
    graph = ManifestGraph()
    manifest = if isfile(projectfile) Base.project_file_manifest_path(projectfile) end
    manifest === nothing && return graph
    entries = get(Base.parsed_toml(manifest), "deps", Dict{String, Any}())::Dict{String, Any}
    uuidof = Dict{String, Base.UUID}(name => Base.UUID(first(infos::Vector{Any})["uuid"]::String)
                                      for (name, infos) in entries)
    for infos in values(entries), info in infos::Vector{Any}
        info = info::Dict{String, Any}
        uuid = Base.UUID(info["uuid"]::String)
        graph.versions[uuid] = if haskey(info, "version") VersionNumber(info["version"]::String) end
        graph.deps[uuid] = dependencyuuids(get(info, "deps", String[]), uuidof)
    end
    graph
end

# `deps` is a list of names, or a name => UUID table when names are ambiguous.
# Names absent from the manifest are skipped, as Base does when resolving them.
function dependencyuuids(@nospecialize(deps), uuidof::Dict{String, Base.UUID})
    deps isa AbstractDict && return Base.UUID[Base.UUID(uuid::String) for uuid in values(deps)]
    uuids = Base.UUID[]
    for name in deps
        haskey(uuidof, name) && push!(uuids, uuidof[name])
    end
    uuids
end

"""
    environment(projectfile::Union{String, Nothing}) -> Environment

The direct deps and manifest graph of `projectfile`, empty without one. A
package project counts among its own deps.
"""
function environment(projectfile::Union{String, Nothing})
    (projectfile === nothing || !isfile(projectfile)) && return (deps = Base.PkgId[], graph = ManifestGraph())
    deps, graph = projectdeps(projectfile), manifestgraph(projectfile)
    project = Base.parsed_toml(projectfile)
    if haskey(project, "name") && haskey(project, "uuid")
        uuid = Base.UUID(project["uuid"]::String)
        graph.versions[uuid] = if haskey(project, "version") VersionNumber(project["version"]::String) end
        push!(deps, Base.PkgId(uuid, project["name"]::String))
    end
    (; deps, graph)
end

function dependencyclosure(graph::ManifestGraph, uuid::Base.UUID)
    closure = Set([uuid])
    pending = [uuid]
    while !isempty(pending)
        for dep in get(graph.deps, pop!(pending), Base.UUID[])
            dep in closure || (push!(closure, dep); push!(pending, dep))
        end
    end
    closure
end

function stdlibids()
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

builtinrecords() =
    [extractnames(m, Base.PkgId(nothing, "Base." * string(nameof(m)))) for m in BUILTIN_MODULES]
