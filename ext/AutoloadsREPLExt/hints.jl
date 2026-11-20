# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The `UndefVarError` hint: the packages providing a name, most readily usable
# first. It never loads anything.

const MAX_HINT_PROVIDERS = 3

# Most readily usable first: hints are ranked in this order.
@enum Availability DirectDep InProjectManifest OnLoadPath AutoloadPackage Elsewhere

struct RankedProvider
    id::Base.PkgId
    owns::Bool
    availability::Availability
    env::Union{String, Nothing}
end

function availability(id::Base.PkgId, deps::Set{Base.UUID}, manifest::Set{Base.UUID}, memberdeps::Set{Base.UUID},
                      loadpathenv::Function)
    id.uuid in deps && return DirectDep, nothing
    id.uuid in manifest && return InProjectManifest, nothing
    env = loadpathenv(id)
    env === nothing || return OnLoadPath, env
    if id.uuid in memberdeps AutoloadPackage else Elsewhere end, nothing
end

function rankproviders(providers, avail::Function)
    ranked = [RankedProvider(id, owns, avail(id)...) for (id, owns) in providers]
    sort!(ranked; by = p -> (p.availability, !p.owns, p.id.name))
    first(ranked, MAX_HINT_PROVIDERS)
end

function formathint(var::Symbol, ranked::Vector{RankedProvider}, sources::Dict{Base.PkgId, Vector{String}}, hasmember::Bool)
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
        elseif hasmember
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

function reexportsources(providers, graph::ManifestGraph)
    owners = [id for (id, owns) in providers if owns]
    sources = Dict{Base.PkgId, Vector{String}}()
    for (id, owns) in providers
        owns && continue
        closure = dependencyclosure(graph, id.uuid)
        used = filter(owner -> owner.uuid in closure, owners)
        sources[id] = [owner.name for owner in if isempty(used) owners else used end]
    end
    sources
end

function undefvarhint(@nospecialize(io::IO), ex::UndefVarError)
    ex.scope === Main || return
    try
        # Base's own hint covers a name a loaded module exports or publishes.
        any(m -> isdefined(m, ex.var) && (Base.isexported(m, ex.var) || Base.ispublic(m, ex.var)), Base.loaded_modules_array()) &&
            return
        session = @atomic SESSION.session
        # Without a session the catalog is read on demand: a few ms, only when an error is shown.
        catalog, member = if session === nothing
            buildcatalog(vcat(builtinrecords(), readcatalog(catalogpath()))), memberdir()
        else
            session.catalog, session.member
        end
        # Rendered through a buffer, so that no printing is compiled for the type of `io`.
        buffer = IOBuffer()
        print(IOContext(buffer, :color => get(io, :color, false)::Bool), providerhint(ex.var, catalog, member))
        print(io, String(take!(buffer)))
    catch err
        err isa InterruptException && rethrow()
        @debug "Autoloads could not build the UndefVarError hint" exception = (err, catch_backtrace())
    end
    nothing
end

function providerhint(var::Symbol, catalog::Catalog, member::String)
    providers = Autoloads.providers(catalog, var)
    isempty(providers) && return styled""
    (; deps, graph) = environment(Base.active_project())
    depuuids = Set{Base.UUID}(id.uuid for id in deps)
    manifest = Set{Base.UUID}(keys(graph.versions))
    memberproject = joinpath(member, "Project.toml")
    memberdeps = Set{Base.UUID}(id.uuid for id in projectdeps(memberproject))
    avail(id) = availability(id, depuuids, manifest, memberdeps, loadpathenv)
    formathint(var, rankproviders(providers, avail), reexportsources(providers, graph), isfile(memberproject))
end

function loadpathenv(id::Base.PkgId)
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
    isdepotenv = basename(parent) == "environments" && rstrip(normpath(dirname(parent)), '/') in depots
    if isdepotenv "@" * basename(dir) else env end
end
