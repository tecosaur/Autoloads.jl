# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

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
    if id.uuid in member_deps AutoloadPackage else Elsewhere end, nothing
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
    format_hint(var, ranked, sources, has_member) -> AnnotatedString

The hint for `var`: per provider, how to get it and a note. `sources` maps a
re-exporter to the names of the owners its note cites (see
[`reexport_sources`](@ref)); `has_member` selects between advising
`autoloads add` and `autoloads init`.
"""
function format_hint(var::Symbol, ranked::Vector{RankedProvider}, sources::Dict{Base.PkgId, Vector{String}}, has_member::Bool)
    hint = styled"\nHint: {code:$var} is provided by packages that are not loaded:"
    for p in ranked
        name = p.id.name
        command, note = if p.availability == DirectDep
            "using $name", "a dependency of the active project"
        elseif p.availability == InProjectManifest
            "pkg> add $name", "already resolved in the active project's manifest"
        elseif p.availability == OnLoadPath
            "using $name", "from $(p.env)"
        elseif p.availability == AutoloadPackage
            "using $name", "an autoload package"
        elseif has_member
            "pkg> add $name", "or pkg> autoloads add $name"
        else
            "pkg> add $name", "run pkg> autoloads init to autoload packages"
        end
        cited = get(sources, p.id, String[])
        p.owns || isempty(cited) || (note *= ", re-exports it from " * join(cited, " and "))
        hint *= styled"\n  {shadow:•} {code:$command}  {shadow:($note)}"
    end
    hint
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
        closure = dependency_closure(graph, id.uuid)
        used = filter(owner -> owner.uuid in closure, owners)
        sources[id] = [owner.name for owner in if isempty(used) owners else used end]
    end
    sources
end

"""
    undefvar_hint(io, ex)

`Base.Experimental` error hint for `UndefVarError`: for a name in `Main` that
no loaded module provides, list the cataloged packages that do. Reads the
catalog file when no session is running. Never throws.
"""
function undefvar_hint(@nospecialize(io::IO), ex::UndefVarError)
    ex.scope === Main || return
    try
        is_provided_by_loaded_module(ex.var) && return
        session = @atomic SESSION.session
        # Without a session the catalog is read on demand: a few ms, only when an error is shown.
        catalog, member = if session === nothing
            build_catalog(vcat(builtin_records(), read_catalog(catalog_path()))), member_dir()
        else
            session.catalog, session.member
        end
        # Rendered through a buffer, so that no printing is compiled for the type of `io`.
        buffer = IOBuffer()
        print(IOContext(buffer, :color => get(io, :color, false)::Bool), provider_hint(ex.var, catalog, member))
        print(io, String(take!(buffer)))
    catch err
        err isa InterruptException && rethrow()
        @debug "Autoloads could not build the UndefVarError hint" exception = (err, catch_backtrace())
    end
    nothing
end

"The hint for `var`: its providers in `catalog`, ranked for the active project and `member`. Empty without providers."
function provider_hint(var::Symbol, catalog::Catalog, member::String)
    providers = Autoloads.providers(catalog, var)
    isempty(providers) && return styled""
    (; deps, graph) = environment(Base.active_project())
    deps_uuids = Set{Base.UUID}(id.uuid for id in deps)
    manifest = Set{Base.UUID}(keys(graph.versions))
    member_project = joinpath(member, "Project.toml")
    member_deps = Set{Base.UUID}(id.uuid for id in project_deps(member_project))
    avail(id) = availability(id, deps_uuids, manifest, member_deps, loadpath_env)
    format_hint(var, rank_providers(providers, avail), reexport_sources(providers, graph), isfile(member_project))
end

# Base's own hint covers a name a loaded module exports or publishes.
function is_provided_by_loaded_module(var::Symbol)
    any(Base.loaded_modules_array()) do m
        isdefined(m, var) && (Base.isexported(m, var) || Base.ispublic(m, var))
    end
end

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
    dir = if isdir(env) env else dirname(env) end
    parent = dirname(dir)
    depots = [rstrip(normpath(depot), '/') for depot in DEPOT_PATH]
    is_depot_env = basename(parent) == "environments" && rstrip(normpath(dirname(parent)), '/') in depots
    if is_depot_env "@" * basename(dir) else env end
end
