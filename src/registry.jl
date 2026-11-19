# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Pure lookups over the catalog, and the registry of names that may autoload.

"""
    Catalog

Catalog records by package, and a name → providers index over each package's
newest namespace, as seen from Julia minor `julia`. Build with `build_catalog`.
"""
struct Catalog
    records::Dict{Base.PkgId, Vector{CatalogRecord}}
    providers::Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}
    julia::VersionNumber
end

"""
    Registry

The names that may autoload: `owners` maps a name to its one provider,
`shared` to the packages re-exporting it from one origin, and `ambiguous` to
its rival claimants. Build with `build_registry`.
"""
struct Registry
    owners::Dict{Symbol, Base.PkgId}
    shared::Dict{Symbol, Vector{Base.PkgId}}
    ambiguous::Dict{Symbol, Vector{Base.PkgId}}
end

"""
    LoadRequest(id, trigger, name)

Load package `id`, or only its `name` if set, because `trigger` was referenced.
"""
struct LoadRequest
    id::Base.PkgId
    trigger::Symbol
    name::Union{Symbol, Nothing}
end

function build_catalog(records; julia::VersionNumber = JULIA_MINOR)
    grouped = Dict{Base.PkgId, Vector{CatalogRecord}}()
    for record in records
        grouped[record.id] = merge_observation(get(grouped, record.id, CatalogRecord[]), record)
    end
    providers = Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}()
    for id in sort!(collect(keys(grouped)); by = pkg_order)
        newest = best_names(grouped[id], nothing, julia)
        newest === nothing && continue
        for name in newest.exported ∪ newest.reexported
            push!(get!(providers, name, Tuple{Base.PkgId, Bool}[]), (id, name in newest.exported))
        end
    end
    Catalog(grouped, providers, julia)
end

records_of(cat::Catalog, id::Base.PkgId) = get(cat.records, id, CatalogRecord[])

"""
    names_at(cat, id, version) -> Union{PkgNames, Nothing}

The record of `id` at `version` (the newest, for `nothing`), seen on the
catalog's Julia minor or else the nearest other, older ones first.
"""
names_at(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing}) =
    best_names(records_of(cat, id), version, cat.julia)

function failed_at(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    records = records_of(cat, id)
    index = findfirst(r -> r isa PkgFailure && (; version, cat.julia) in r.at, records)
    if index !== nothing records[index] end
end

"""
    providers(cat, name) -> Vector{Tuple{Base.PkgId, Bool}}

The `(id, owns)` packages whose newest namespace exports (`owns`) or re-exports `name`.
"""
providers(cat::Catalog, name::Symbol) = get(cat.providers, name, Tuple{Base.PkgId, Bool}[])

"""
    autoload_set(member_deps, member_graph, project_deps, project_graph,
                 stdlibs, builtins, cfg) -> Dict{Base.PkgId, Union{VersionNumber, Nothing}}

The packages to autoload, with their versions: the member's deps, stdlibs and
built-ins if `cfg.stdlib`, and the active project's selected deps, whose
versions win.
"""
function autoload_set(member_deps, member_graph::ManifestGraph, project_deps, project_graph::ManifestGraph,
                      stdlibs, builtins, cfg::Config)
    version_in(graph, id) = get(graph.versions, id.uuid, nothing)
    wanted = Dict{Base.PkgId, Union{VersionNumber, Nothing}}()
    for id in member_deps
        wanted[id] = version_in(member_graph, id)
    end
    if cfg.stdlib
        for id in stdlibs
            wanted[id] = something(version_in(project_graph, id), version_in(member_graph, id), Some(nothing))
        end
        for id in builtins
            wanted[id] = nothing
        end
    end
    for id in project_deps
        (cfg.project === nothing || id.name in cfg.project) && (wanted[id] = version_in(project_graph, id))
    end
    wanted
end

"""
    build_registry(cat, autoload, cfg) -> Registry

Assign the names the packages in `autoload` offer: each to its one owner, else
its one re-exporter, or shared by re-exporters of one origin; anything else is
ambiguous.
"""
function build_registry(cat::Catalog, autoload::AbstractDict, cfg::Config)
    owning = Dict{Symbol, Vector{Base.PkgId}}()
    reexporting = Dict{Symbol, Vector{Base.PkgId}}()
    records = Dict{Base.PkgId, PkgNames}()
    for id in sort!(collect(keys(autoload)); by = pkg_order)
        record = @something(names_at(cat, id, autoload[id]), names_at(cat, id, nothing), continue)
        records[id] = record
        for name in autoload_names(record, package_config(cfg, id.name))
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

is_candidate(reg::Registry, name::Symbol) = haskey(reg.owners, name) || haskey(reg.shared, name)

"""
    pending_loads(reg, cfg, names, isbound, isloaded, attempted) -> Vector{LoadRequest}

The loads the referenced `names` need, skipping bound names and pairs in
`attempted`. A shared name loads from the first of its packages that is loaded
or being loaded here. `UsedBindings` packages get one request per name.
"""
function pending_loads(reg::Registry, cfg::Config, names, isbound::Function, isloaded::Function,
                       attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}})
    requests = LoadRequest[]
    queued = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    function request!(id, name)
        target = if bindings_for(cfg, id.name) == UsedBindings name end
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
    to_index(cat, wanted) -> Vector{Base.PkgId}

The packages in `wanted` that this Julia minor has neither indexed at their
version (any version, for `nothing`) nor recorded as failing.
"""
function to_index(cat::Catalog, wanted::AbstractDict)
    function has_names_here(id, version)
        any(records_of(cat, id)) do record
            record isa PkgNames && any(record.at) do sighting
                sighting.julia == cat.julia && (version === nothing || sighting.version == version)
            end
        end
    end
    missing_ids = [id for (id, version) in wanted
                   if !has_names_here(id, version) && failed_at(cat, id, version) === nothing]
    sort!(missing_ids; by = pkg_order)
end

# ── Helpers ──

pkg_order(id::Base.PkgId) = (id.name, string(id.uuid))

function best_names(records::Vector{CatalogRecord}, version::Union{VersionNumber, Nothing}, julia::VersionNumber)
    # Higher is better: this minor, then older ones nearest first, then newer; then the newest version.
    best, best_rank = nothing, nothing
    for record in records, sighting in (if record isa PkgNames record.at else () end)
        version === nothing || sighting.version == version || continue
        # Higher is better: this minor, then older ones nearest first, then newer; then the newest version.
        (; major, minor) = seen = sighting.julia
        is_older = seen <= julia
        rank = (is_older, if is_older; (major, minor) else (-major, -minor) end, version_order(sighting.version))
        if best_rank === nothing || rank > best_rank
            best, best_rank = record, rank
        end
    end
    best
end
