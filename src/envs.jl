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

"The directory of this Julia version's global environment (`@v#.#`)."
global_env_dir() = dirname(Base.load_path_expand("@v#.#"))

"""
    member_dir(global_dir = global_env_dir())

The `autoloads` workspace member of the global environment in `global_dir`.
"""
member_dir(global_dir = global_env_dir()) = joinpath(global_dir, "autoloads")

"The package catalog file for this Julia version, in the first depot."
catalog_path() = joinpath(first(DEPOT_PATH), "autoloads",
                          "v$(VERSION.major).$(VERSION.minor)", "catalog-v1")

"""
    project_deps(project_file) -> Vector{Base.PkgId}

The `[deps]` of `project_file`; empty when the file does not exist.
"""
function project_deps(project_file::AbstractString)
    isfile(project_file) || return Base.PkgId[]
    deps = get(Base.parsed_toml(project_file), "deps", Dict{String, Any}())
    [Base.PkgId(Base.UUID(uuid), name) for (name, uuid) in deps]
end

"""
    manifest_graph(project_file) -> ManifestGraph

The graph of the manifest Base would use for `project_file` (a workspace
member gets the root's; versioned manifest names are honoured). Empty when
there is no manifest.
"""
function manifest_graph(project_file::AbstractString)
    versions = Dict{Base.UUID, Union{VersionNumber, Nothing}}()
    deps = Dict{Base.UUID, Vector{Base.UUID}}()
    manifest = isfile(project_file) ? Base.project_file_manifest_path(project_file) : nothing
    manifest === nothing && return ManifestGraph(versions, deps)
    entries = get(Base.parsed_toml(manifest), "deps", Dict{String, Any}())
    uuid_of = Dict(name => Base.UUID(first(infos)["uuid"]) for (name, infos) in entries)
    for infos in values(entries), info in infos
        uuid = Base.UUID(info["uuid"])
        versions[uuid] = haskey(info, "version") ? VersionNumber(info["version"]) : nothing
        deps[uuid] = dependency_uuids(get(info, "deps", String[]), uuid_of)
    end
    ManifestGraph(versions, deps)
end

# `deps` is a list of names, or a name => UUID table when names are ambiguous.
# Names absent from the manifest are skipped, as Base does when resolving them.
dependency_uuids(names::AbstractVector, uuid_of) =
    [uuid_of[name] for name in names if haskey(uuid_of, name)]
dependency_uuids(table::AbstractDict, _) = [Base.UUID(uuid) for uuid in values(table)]

"""
    environment(project_file) -> (; deps::Vector{Base.PkgId}, graph::ManifestGraph)

The direct deps and manifest graph of `project_file`; empty for `nothing` or a
missing file.
"""
function environment(project_file::Union{String, Nothing})
    project_file === nothing &&
        return (deps = Base.PkgId[], graph = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(),
                                                           Dict{Base.UUID, Vector{Base.UUID}}()))
    (deps = project_deps(project_file), graph = manifest_graph(project_file))
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
function run_julia(args::Cmd; project, env = (), nice::Bool = false,
                   detach::Bool = false, output = stdout)
    cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no`
    project === nothing || (cmd = `$cmd --project=$project`)
    cmd = `$cmd $args`
    nice && Sys.which("nice") !== nothing && (cmd = `nice -n 10 $cmd`)
    cmd = addenv(cmd, env...)
    detach && (cmd = Base.detach(cmd))
    run(pipeline(cmd; stdout = output, stderr = output); wait = false)
end

"Tell whoever registered in [`ENV_CHANGED`](@ref) that the environment changed."
notify_env_change() = ENV_CHANGED[] === nothing || ENV_CHANGED[]()
