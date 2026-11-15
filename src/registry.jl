# Catalog and registry: the catalog records which names each package provides
# per version; the registry is the immutable name -> owning package view of
# what may autoload. Everything here is pure.

"""
    Catalog

Catalog records grouped by package id, plus a name -> providers index over
each package's newest [`PkgNames`](@ref) (exported and re-exported names).
Build with [`build_catalog`](@ref).
"""
struct Catalog
    records::Dict{Base.PkgId, Vector{CatalogRecord}}
    providers::Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}
end

"""
    Registry

The names that may autoload: `owners` maps a name to the one package that
provides it, `ambiguous` maps contested names to their claimants. Build with
[`build_registry`](@ref).
"""
struct Registry
    owners::Dict{Symbol, Base.PkgId}
    ambiguous::Dict{Symbol, Vector{Base.PkgId}}
end

"""
    LoadRequest(id, trigger, name)

Load package `id` because `trigger` was referenced. `name === nothing` asks
for the whole package; otherwise only `name`.
"""
struct LoadRequest
    id::Base.PkgId
    trigger::Symbol
    name::Union{Symbol, Nothing}
end

"""
    build_catalog(records) -> Catalog

Fold `records` in order with [`merge_observation`](@ref).
"""
function build_catalog(records)
    grouped = Dict{Base.PkgId, Vector{CatalogRecord}}()
    for record in records
        grouped[record.id] = merge_observation(get(grouped, record.id, CatalogRecord[]), record)
    end
    providers = Dict{Symbol, Vector{Tuple{Base.PkgId, Bool}}}()
    for id in sort!(collect(keys(grouped)); by = id -> (id.name, string(id.uuid)))
        newest = newest_names(grouped[id])
        newest === nothing && continue
        for name in newest.exported ∪ newest.reexported
            push!(get!(providers, name, Tuple{Base.PkgId, Bool}[]), (id, name in newest.exported))
        end
    end
    Catalog(grouped, providers)
end

"All records for `id`, or an empty vector."
records_of(cat::Catalog, id::Base.PkgId) = get(cat.records, id, CatalogRecord[])

"""
    names_at(cat, id, version) -> Union{PkgNames, Nothing}

The record of `id` containing `version`; for `nothing`, its newest record.
"""
function names_at(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    version === nothing && return newest_names(records_of(cat, id))
    index = findfirst(r -> r isa PkgNames && version in r.versions, records_of(cat, id))
    index === nothing ? nothing : records_of(cat, id)[index]
end

"The [`PkgFailure`](@ref) recorded for `id` at `version`, or `nothing`."
function failed_at(cat::Catalog, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    index = findfirst(r -> r isa PkgFailure && r.version == version, records_of(cat, id))
    index === nothing ? nothing : records_of(cat, id)[index]
end

"""
    providers(cat, name) -> Vector{Tuple{Base.PkgId, Bool}}

Packages whose newest namespace exports or re-exports `name`, as
`(id, owns)` pairs sorted by package name; `owns` is false for re-exports.
"""
providers(cat::Catalog, name::Symbol) = get(cat.providers, name, Tuple{Base.PkgId, Bool}[])

"""
    autoload_set(member_deps, member_graph, project_deps, project_graph,
                 stdlibs, builtins, cfg) -> Dict{Base.PkgId, Union{VersionNumber, Nothing}}

The packages to autoload and their versions: member-environment deps (at
`member_graph` versions), stdlibs and built-ins when `cfg.stdlib`, and the
active project's direct deps selected by `cfg.project` (at `project_graph`
versions, winning over the other sources).
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

Index the names of each package in `autoload` (the record at its version,
else its newest). A name owned by exactly one package goes to it; failing
that, one re-exporter gets it; anything else is ambiguous.
"""
function build_registry(cat::Catalog, autoload::AbstractDict, cfg::Config)
    owning = Dict{Symbol, Vector{Base.PkgId}}()
    reexporting = Dict{Symbol, Vector{Base.PkgId}}()
    for (id, version) in sort!(collect(autoload); by = ((id, _),) -> (id.name, string(id.uuid)))
        record = something(names_at(cat, id, version), names_at(cat, id, nothing), Some(nothing))
        record === nothing && continue
        for name in autoload_names(record, package_config(cfg, id.name))
            push!(get!(name in record.exported ? owning : reexporting, name, Base.PkgId[]), id)
        end
    end
    owners = Dict{Symbol, Base.PkgId}()
    ambiguous = Dict{Symbol, Vector{Base.PkgId}}()
    for name in keys(owning) ∪ keys(reexporting)
        claimants = haskey(owning, name) ? owning[name] : reexporting[name]
        length(claimants) == 1 ? (owners[name] = only(claimants)) : (ambiguous[name] = claimants)
    end
    Registry(owners, ambiguous)
end

"The package that owns `name`, or `nothing`."
owner(reg::Registry, name::Symbol) = get(reg.owners, name, nothing)

"Whether `name` is owned by an autoload package."
is_candidate(reg::Registry, name::Symbol) = haskey(reg.owners, name)

"The contested names and their claimant packages."
ambiguities(reg::Registry) = reg.ambiguous

"""
    pending_loads(reg, cfg, names, isbound, attempted) -> Vector{LoadRequest}

Loads needed for the referenced `names`, skipping names for which
`isbound(name)` holds and `(id, name)` pairs in `attempted` (`name` is
`nothing` for whole-package loads). Packages in `AllBindings` mode yield one
whole-package request; in `UsedBindings` mode one request per name.
"""
function pending_loads(reg::Registry, cfg::Config, names, isbound::Function,
                       attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}})
    requests = LoadRequest[]
    queued = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    for name in names
        id = owner(reg, name)
        (id === nothing || isbound(name)) && continue
        target = bindings_for(cfg, id.name) == AllBindings ? nothing : name
        key = (id, target)
        (key in attempted || key in queued) && continue
        push!(queued, key)
        push!(requests, LoadRequest(id, name, target))
    end
    requests
end

"""
    to_index(cat, wanted) -> Vector{Base.PkgId}

Packages in `wanted` whose version has neither a namespace record nor a
recorded failure. A `nothing` version is covered by any namespace record.
"""
function to_index(cat::Catalog, wanted::AbstractDict)
    missing_ids = [id for (id, version) in wanted
                   if names_at(cat, id, version) === nothing && failed_at(cat, id, version) === nothing]
    sort!(missing_ids; by = id -> (id.name, string(id.uuid)))
end

# ── Helpers ──

function newest_names(records::Vector{CatalogRecord})
    names = filter(r -> r isa PkgNames, records)
    isempty(names) ? nothing : argmax(r -> isempty(r.versions) ? v"0" : maximum(r.versions), names)
end
