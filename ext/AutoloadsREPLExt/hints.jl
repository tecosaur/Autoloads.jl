# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The `UndefVarError` hint: the packages providing a name, most readily usable
# first. It never loads anything.

const MAX_HINT_PROVIDERS = 3

# Most readily usable first: hints are ranked in this order. An outdated
# package's installed version lacks the name, which a newer one offers.
@enum Availability Builtin DirectDep InProjectManifest Outdated OnLoadPath AutoloadPackage OutdatedAutoload Elsewhere

struct RankedProvider
    id::Base.PkgId
    owns::Bool
    availability::Availability
    env::Union{String, Nothing}
    versions::Union{Pair{VersionNumber, VersionNumber}, Nothing}  # installed => newer, when outdated
end

function availability(id::Base.PkgId, project::Environment, member::Environment, loadpathenv::Function,
                      newerwith::Function)
    id.uuid === nothing && return Builtin, nothing, nothing
    function outdated(graph::ManifestGraph)
        installed = @something(get(graph.versions, id.uuid, nothing), return nothing)
        newer = @something(newerwith(id, installed), return nothing)
        installed => newer
    end
    isdep = any(dep -> dep.uuid == id.uuid, project.deps)
    if isdep || haskey(project.graph.versions, id.uuid)
        versions = outdated(project.graph)
        versions === nothing || return Outdated, nothing, versions
        return if isdep DirectDep else InProjectManifest end, nothing, nothing
    end
    env = loadpathenv(id)
    env === nothing || return OnLoadPath, env, nothing
    any(dep -> dep.uuid == id.uuid, member.deps) || return Elsewhere, nothing, nothing
    versions = outdated(member.graph)
    if versions === nothing AutoloadPackage else OutdatedAutoload end, nothing, versions
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
        command, note = if p.availability == Builtin
            "using $name", "part of Julia"
        elseif p.availability == DirectDep
            "using $name", "a dependency of the active project"
        elseif p.availability == InProjectManifest
            "pkg> add $name", "already resolved in the active project's manifest"
        elseif p.availability in (Outdated, OutdatedAutoload)
            installed, newer = something(p.versions)
            if p.availability == Outdated "pkg> up $name" else "pkg> autoloads up $name" end,
                "$var is in $name v$newer; v$installed is installed"
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
            buildcatalog(CatalogRecord[builtinrecords(); readcatalog(catalogpath())]), memberdir()
        else
            session.catalog, session.member
        end
        # Rendered through a buffer, so that no printing is compiled for the type of `io`.
        buffer = IOBuffer()
        print(IOContext(buffer, :color => get(io, :color, false)::Bool), providerhint(ex.var, catalog, member))
        print(io, String(take!(buffer)))
    catch err
        isinterrupt(err) && rethrow()
        @debug "Autoloads could not build the UndefVarError hint" exception = (err, catch_backtrace())
    end
    nothing
end

function providerhint(var::Symbol, catalog::Catalog, member::String)
    providers = Autoloads.providers(catalog, var)
    isempty(providers) && return styled""
    project = environment(Base.active_project())
    memberproject = joinpath(member, "Project.toml")
    memberenv = environment(memberproject)
    # The newest version known to offer `var`, when the installed one is known not to.
    function newerwith(id, installed)
        record = @something(namesat(catalog, id, installed), return nothing)
        (var in record.exported || var in record.reexported) && return nothing
        newest = maximum(s.version for s in something(namesat(catalog, id, nothing)).at if s.version !== nothing;
                         init = installed)
        if newest > installed newest end
    end
    avail(id) = availability(id, project, memberenv, loadpathenv, newerwith)
    formathint(var, rankproviders(providers, avail), reexportsources(providers, project.graph), isfile(memberproject))
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
