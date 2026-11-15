# The `UndefVarError` hint: for a name no loaded module provides, list the
# packages that export it, ranked by how readily they can be used. It only
# suggests; it never loads anything. A pure ranking core (`availability`,
# `rank_providers`, `format_hint`) sits behind the I/O in `undefvar_hint`.

const MAX_HINT_PROVIDERS = 3

"How readily a package can be used, most ready first."
@enum Availability DirectDep InProjectManifest OnLoadPath AutoloadPackage Elsewhere

"A provider as listed in the hint: `env` names the load-path environment for `OnLoadPath`."
struct RankedProvider
    id::Base.PkgId
    owns::Bool
    availability::Availability
    env::Union{String, Nothing}
end

"""
    availability(id, deps, manifest, member_deps, loadpath_env) -> (Availability, Union{String, Nothing})

How readily `id` can be used given the active project's direct `deps` and
`manifest`, and the autoloads member's direct `member_deps` (package UUIDs).
`loadpath_env(id)` gives the display name of the load-path environment
providing `id`, or `nothing`; the name is returned for `OnLoadPath` and is
`nothing` otherwise.
"""
function availability(id::Base.PkgId, deps::Set{Base.UUID}, manifest::Set{Base.UUID}, member_deps::Set{Base.UUID},
                      loadpath_env::Function)
    id.uuid in deps && return DirectDep, nothing
    id.uuid in manifest && return InProjectManifest, nothing
    env = loadpath_env(id)
    env === nothing || return OnLoadPath, env
    (id.uuid in member_deps ? AutoloadPackage : Elsewhere), nothing
end

"""
    rank_providers(providers, avail) -> Vector{RankedProvider}

The best [`MAX_HINT_PROVIDERS`](@ref) of `providers` (`(id, owns)` pairs),
ordered by availability (`avail(id)`), then owners before re-exporters, then name.
"""
function rank_providers(providers, avail::Function)
    ranked = [RankedProvider(id, owns, avail(id)...) for (id, owns) in providers]
    sort!(ranked; by = p -> (p.availability, !p.owns, p.id.name))
    first(ranked, MAX_HINT_PROVIDERS)
end

"""
    format_hint(var, ranked, sources, has_member) -> String

The hint text for `var`. `sources` maps a re-exporter to the names of the
owners cited on its line (see [`reexport_sources`](@ref)); `has_member` selects between advising
`autoloads add` and `autoloads init`.
"""
function format_hint(var::Symbol, ranked::Vector{RankedProvider}, sources::Dict{Base.PkgId, Vector{String}}, has_member::Bool)
    io = IOBuffer()
    print(io, "\nHint: ", var, " is provided by packages that are not loaded:")
    for p in ranked
        name = p.id.name
        print(io, "\n    - ")
        if p.availability == DirectDep
            print(io, "`using $name` (a dependency of the active project)")
        elseif p.availability == InProjectManifest
            print(io, "`pkg> add $name` (already resolved in the active project's manifest)")
        elseif p.availability == OnLoadPath
            print(io, "`using $name` (from $(p.env))")
        elseif p.availability == AutoloadPackage
            print(io, "`using $name` (an autoload package)")
        elseif has_member
            print(io, "`pkg> add $name`, or `pkg> autoloads add $name`")
        else
            print(io, "`pkg> add $name` (run `pkg> autoloads init` to autoload packages)")
        end
        cited = get(sources, p.id, String[])
        p.owns || isempty(cited) || print(io, ", which re-exports it from ", join(cited, " and "))
    end
    String(take!(io))
end

"""
    reexport_sources(providers, graph) -> Dict{Base.PkgId, Vector{String}}

For each re-exporter among `providers` (`(id, owns)` pairs), the owners it
depends on in the manifest `graph`; all owners when it is not in the manifest
or depends on none.
"""
function reexport_sources(providers, graph::ManifestGraph)
    owners = [id for (id, owns) in providers if owns]
    sources = Dict{Base.PkgId, Vector{String}}()
    for (id, owns) in providers
        owns && continue
        closure = haskey(graph.versions, id.uuid) ? dependency_closure(graph, id.uuid) : Set{Base.UUID}()
        used = filter(owner -> owner.uuid in closure, owners)
        cited = isempty(used) ? owners : used
        sources[id] = [owner.name for owner in cited]
    end
    sources
end

"""
    undefvar_hint(io, ex)

`Base.Experimental` error hint for `UndefVarError`: for a name in `Main` that
no loaded module provides, list the cataloged packages that do. Reads the
catalog file when no session is running. Never throws.
"""
function undefvar_hint(io::IO, ex::UndefVarError)
    ex.scope === Main || return
    try
        is_provided_by_loaded_module(ex.var) && return
        session = @atomic SESSION.session
        catalog = session === nothing ? read_hint_catalog() : session.catalog
        providers = Autoloads.providers(catalog, ex.var)
        isempty(providers) && return
        (; deps, graph) = environment(Base.active_project())
        deps_uuids = Set{Base.UUID}(id.uuid for id in deps)
        manifest = Set{Base.UUID}(keys(graph.versions))
        member_project = joinpath(session === nothing ? member_dir() : session.member, "Project.toml")
        member_deps = Set{Base.UUID}(id.uuid for id in project_deps(member_project))
        avail(id) = availability(id, deps_uuids, manifest, member_deps, loadpath_env)
        ranked = rank_providers(providers, avail)
        sources = reexport_sources(providers, graph)
        has_member = isfile(member_project)
        print(io, format_hint(ex.var, ranked, sources, has_member))
    catch err
        err isa InterruptException && rethrow()
        @debug "Autoloads could not build the UndefVarError hint" exception = (err, catch_backtrace())
    end
    nothing
end

# Base's own hint covers a name a loaded module exports or publishes.
function is_provided_by_loaded_module(var::Symbol)
    any(Base.loaded_modules_array()) do m
        isdefined(m, var) && (Base.isexported(m, var) || Base.ispublic(m, var))
    end
end

# Without a session the catalog is read on demand: a few ms, only when an error is shown.
read_hint_catalog() = build_catalog(vcat(builtin_records(), read_catalog(catalog_path())))

"The load-path environment that resolves `id`, as Pkg names it (`@v1.13`, `@stdlib`, else the path), or `nothing`."
function loadpath_env(id::Base.PkgId)
    # Never block an error display behind a `require` in another task.
    trylock(Base.require_lock) || return nothing
    found = try
        Base.identify_package_env(id.name)
    finally
        unlock(Base.require_lock)
    end
    (found === nothing || found[1] != id) && return nothing
    env = found[2]
    env == Sys.STDLIB && return "@stdlib"
    dir = isdir(env) ? env : dirname(env)
    parent = dirname(dir)
    depots = [rstrip(normpath(depot), '/') for depot in DEPOT_PATH]
    basename(parent) == "environments" && rstrip(normpath(dirname(parent)), '/') in depots ? "@" * basename(dir) : env
end
