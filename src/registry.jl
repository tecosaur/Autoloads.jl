# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Lookups over the catalog, the registry of names that may autoload, and the
# session joining them with the environments.

struct Catalog
    records::Dict{Base.PkgId, Vector{CatalogRecord}}
    providers::Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}
    julia::VersionNumber
end

struct Registry
    owners::Dict{Symbol, Base.PkgId}
    shared::Dict{Symbol, Vector{Base.PkgId}}
    ambiguous::Dict{Symbol, Vector{Base.PkgId}}
end

struct LoadRequest
    id::Base.PkgId
    trigger::Symbol
    name::Union{Symbol, Nothing}
end

# A catalog file's records are already merged per package, so they are only grouped.
function buildcatalog(records; julia::VersionNumber = JULIA_MINOR)
    grouped = Dict{Base.PkgId, Vector{CatalogRecord}}()
    foreach(r -> push!(get!(grouped, r.id, CatalogRecord[]), r), records)
    providers = Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}()
    for id in sort!(collect(keys(grouped)); by = pkgorder)
        newest = bestnames(grouped[id], nothing, julia)
        newest === nothing && continue
        for name in newest.exported ∪ newest.reexported
            push!(get!(providers, name, Tuple{Base.PkgId, Bool}[]), (id, name in newest.exported))
        end
    end
    Catalog(grouped, providers, julia)
end

recordsof(cat::Catalog, id::Base.PkgId) = get(cat.records, id, CatalogRecord[])

"""
    namesat(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing}) -> Union{PkgNames, Nothing}

The record of `id` at `version` (the newest, for `nothing`), seen on the
catalog's Julia minor or else the nearest other, older ones first.
"""
namesat(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing}) =
    bestnames(recordsof(cat, id), version, cat.julia)

function failedat(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    for record in recordsof(cat, id)
        record isa PkgFailure && Sighting((version, cat.julia)) in record.at && return record
    end
end

providers(cat::Catalog, name::Symbol) = get(cat.providers, name, Tuple{Base.PkgId, Bool}[])

"""
    autoloadset(memberdeps, membergraph, projectdeps, projectgraph,
                 stdlibs, builtins, cfg) -> Dict{Base.PkgId, Union{VersionNumber, Nothing}}

The packages to autoload, with their versions: the member's deps, stdlibs and
built-ins if `cfg.stdlib`, and the active project's selected deps, whose
versions win.
"""
function autoloadset(memberdeps, membergraph::ManifestGraph, projectdeps, projectgraph::ManifestGraph,
                      stdlibs, builtins, cfg::Config)
    versionin(graph, id) = get(graph.versions, id.uuid, nothing)
    wanted = Dict{Base.PkgId, Union{VersionNumber, Nothing}}()
    for id in memberdeps
        wanted[id] = versionin(membergraph, id)
    end
    if cfg.stdlib
        for id in stdlibs
            wanted[id] = something(versionin(projectgraph, id), versionin(membergraph, id), Some(nothing))
        end
        for id in builtins
            wanted[id] = nothing
        end
    end
    (; project) = cfg
    for id in projectdeps
        (project === nothing || id.name in project) && (wanted[id] = versionin(projectgraph, id))
    end
    wanted
end

"""
    buildregistry(cat::Catalog, autoload::AbstractDict, cfg::Config) -> Registry

Assign the names the packages in `autoload` offer: each to its one owner, else
its one re-exporter, or shared by re-exporters of one origin; anything else is
ambiguous.
"""
function buildregistry(cat::Catalog, autoload::AbstractDict, cfg::Config)
    owning = Dict{Symbol, Vector{Base.PkgId}}()
    reexporting = Dict{Symbol, Vector{Base.PkgId}}()
    records = Dict{Base.PkgId, PkgNames}()
    for id in sort!(collect(keys(autoload)); by = pkgorder)
        record = @something(namesat(cat, id, autoload[id]), namesat(cat, id, nothing), continue)
        records[id] = record
        for name in autoloadnames(record, packageconfig(cfg, id.name))
            push!(get!(if name in record.exported owning else reexporting end, name, Base.PkgId[]), id)
        end
    end
    owners = Dict{Symbol, Base.PkgId}()
    shared, ambiguous = Dict{Symbol, Vector{Base.PkgId}}(), Dict{Symbol, Vector{Base.PkgId}}()
    for name in keys(owning) ∪ keys(reexporting)
        claimants = get(() -> reexporting[name], owning, name)
        origins = unique!([get(records[id].origins, name, nothing) for id in claimants])
        if length(claimants) == 1
            owners[name] = only(claimants)
        elseif !haskey(owning, name) && length(origins) == 1 && only(origins) !== nothing
            shared[name] = claimants
        else
            ambiguous[name] = claimants
        end
    end
    Registry(owners, shared, ambiguous)
end

owner(reg::Registry, name::Symbol) = get(reg.owners, name, nothing)

iscandidate(reg::Registry, name::Symbol) = haskey(reg.owners, name) || haskey(reg.shared, name)

"""
    pendingloads(reg::Registry, cfg::Config, names, isbound::Function, isloaded::Function, attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}) -> Vector{LoadRequest}

The loads the referenced `names` need, skipping bound names and pairs in
`attempted`. A shared name loads from the first of its packages that is loaded
or being loaded here. `UsedBindings` packages get one request per name.
"""
function pendingloads(reg::Registry, cfg::Config, names, isbound::Function, isloaded::Function,
                       attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}})
    requests = LoadRequest[]
    queued = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    function request!(id, name)
        target = if something(packageconfig(cfg, id.name).bindings, cfg.bindings) == UsedBindings name end
        key = (id, target)
        (key in attempted || key in queued) && return
        push!(queued, key)
        push!(requests, LoadRequest(id, name, target))
    end
    unbound = [name for name in names if !isbound(name)]
    for name in unbound
        id = owner(reg, name)
        id === nothing || request!(id, name)
    end
    for name in unbound
        sharers = get(reg.shared, name, Base.PkgId[])
        index = findfirst(id -> isloaded(id) || any(request -> request.id == id, requests), sharers)
        index === nothing || request!(sharers[index], name)
    end
    requests
end

"""
    unindexed(cat::Catalog, wanted::AbstractDict) -> Vector{Base.PkgId}

The packages in `wanted` that this Julia minor has neither indexed at their
version (any version, for `nothing`) nor recorded as failing.
"""
function unindexed(cat::Catalog, wanted::AbstractDict)
    function indexedhere(id, version)
        any(recordsof(cat, id)) do record
            record isa PkgNames && any(record.at) do sighting
                sighting.julia == cat.julia && (version === nothing || sighting.version == version)
            end
        end
    end
    missingids = [id for (id, version) in wanted
                   if !indexedhere(id, version) && failedat(cat, id, version) === nothing]
    sort!(missingids; by = pkgorder)
end

# The session

struct Session
    config::Config
    member::String
    memberenv::Environment
    active::Union{String, Nothing}
    projectenv::Environment
    catalog::Catalog
    autoload::Dict{Base.PkgId, Union{VersionNumber, Nothing}}
    registry::Registry
end

function Session(config::Config, member::AbstractString, records::Vector{CatalogRecord}, builtins::Vector{PkgNames},
                 stdlibs::Vector{Base.PkgId})
    memberenv = environment(joinpath(member, "Project.toml"))
    active = Base.active_project()
    projectenv = environment(active)
    catalog = buildcatalog(CatalogRecord[builtins; records])
    autoload = autoloadset(memberenv.deps, memberenv.graph, projectenv.deps, projectenv.graph, stdlibs,
                           [record.id for record in builtins], config)
    Session(config, String(member), memberenv, active, projectenv, catalog, autoload,
            buildregistry(catalog, autoload, config))
end

readsession(globaldir::AbstractString, catalog::AbstractString) =
    Session(loadconfig(), memberdir(globaldir), readcatalog(catalog), builtinrecords(), stdlibids())

# Utility functions

pkgorder(id::Base.PkgId) = (id.name, string(id.uuid))

function bestnames(records::Vector{CatalogRecord}, version::Union{VersionNumber, Nothing}, julia::VersionNumber)
    best, bestrank = nothing, nothing
    for record in records
        record isa PkgNames || continue
        for sighting in record.at
            version === nothing || sighting.version == version || continue
            # Higher is better: this minor, then older ones nearest first, then newer; then the newest version.
            (; major, minor) = seen = sighting.julia
            isolder = seen <= julia
            rank = (isolder, if isolder; (major, minor) else (-major, -minor) end, versionorder(sighting.version))
            if bestrank === nothing || rank > bestrank
                best, bestrank = record, rank
            end
        end
    end
    best
end
