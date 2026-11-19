# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Catalog records: what the package catalog knows about each package's
# namespace, and their line-oriented serialisation. Depends only on Base so
# that the standalone indexer script can include it.

# What a name is bound to: a module, function, type or other value. A macro's name says as much.
const NAME_KINDS = ".+:="

"This session's Julia minor version, as records key it."
const JULIA_MINOR = VersionNumber(VERSION.major, VERSION.minor)

"A package `version` (`nothing` if it has none, as a built-in) seen on Julia minor version `julia`."
const Sighting = @NamedTuple{version::Union{VersionNumber, Nothing}, julia::VersionNumber}

"""
    PkgNames(id, at, exported, public, reexported; kinds = Dict(), origins = Dict())

One namespace offered by package `id`, at each [`Sighting`](@ref) in `at`
(sorted, nonempty). `exported` always includes the module's own name. Where
known, `kinds` maps names other than macros to one of [`NAME_KINDS`](@ref),
and `origins` re-exported names to the package owning them. Records for one
`id` have disjoint `at`.
"""
struct PkgNames
    id::Base.PkgId
    at::Vector{Sighting}
    exported::Set{Symbol}
    public::Set{Symbol}
    reexported::Set{Symbol}
    kinds::Dict{Symbol, Char}
    origins::Dict{Symbol, Base.PkgId}
end

PkgNames(id, at, exported, public, reexported; kinds = Dict{Symbol, Char}(), origins = Dict{Symbol, Base.PkgId}()) =
    PkgNames(id, at, exported, public, reexported, kinds, origins)

"""
    PkgFailure(id, at, message)

Package `id` could not be loaded at [`Sighting`](@ref) `at`.
"""
struct PkgFailure
    id::Base.PkgId
    at::Sighting
    message::String
end

const CatalogRecord = Union{PkgNames, PkgFailure}

"Exit code of an indexer subprocess that was interrupted (shell convention, 128 + SIGINT)."
const INTERRUPTED_EXIT_CODE = 130

Base.:(==)(a::PkgNames, b::PkgNames) =
    a.id == b.id && a.at == b.at && same_namespace(a, b)

Base.:(==)(a::PkgFailure, b::PkgFailure) =
    a.id == b.id && a.at == b.at && a.message == b.message

Base.hash(r::PkgNames, h::UInt) =
    hash((r.id, r.at, r.exported, r.public, r.reexported, r.kinds, r.origins), hash(:PkgNames, h))

Base.hash(r::PkgFailure, h::UInt) =
    hash((r.id, r.at, r.message), hash(:PkgFailure, h))

"""
    extract_names(mod, id = Base.PkgId(mod)) -> PkgNames

Collect the namespace `mod` offers, seen at its `pkgversion` on this Julia.
Names defined in `mod` or its submodules are `exported` or `public`; names
exported from other packages are `reexported`; names owned by `Base`/`Core`
are skipped unless `mod` is itself part of `Base`. Undefined bindings and
names containing whitespace are skipped.

# Example
```julia
extract_names(Base.Threads, Base.PkgId(nothing, "Base.Threads")).exported
```
"""
function extract_names(mod::Module, id::Base.PkgId = Base.PkgId(mod))
    is_builtin = is_within(mod, Base)
    exported = Set{Symbol}((nameof(mod),))
    public = Set{Symbol}()
    reexported = Set{Symbol}()
    kinds = Dict{Symbol, Char}(nameof(mod) => '.')
    origins = Dict{Symbol, Base.PkgId}()
    for name in names(mod)
        isdefined(mod, name) && !any(isspace, string(name)) || continue
        owner = Base.binding_module(mod, name)
        is_exported = Base.isexported(mod, name)
        is_core = owner === Base || owner === Core
        if is_within(owner, mod) || (is_builtin && is_core)
            push!(if is_exported exported else public end, name)
        elseif is_exported && !is_core
            push!(reexported, name)
            origins[name] = Base.PkgId(Base.moduleroot(owner))
        else
            continue
        end
        startswith(string(name), '@') && continue
        value = getglobal(mod, name)
        kinds[name] = if value isa Module '.' elseif value isa Function '+' elseif value isa Type ':' else '=' end
    end
    PkgNames(id, Sighting[(; version = pkgversion(mod), julia = JULIA_MINOR)], exported, public, reexported, kinds, origins)
end

"""
    merge_observation(existing, new) -> Vector{CatalogRecord}

Return the records for one package after observing `new`, a [`PkgNames`](@ref)
or a [`PkgFailure`](@ref). A `PkgNames` seen at several sightings is observed
one sighting at a time, in order. The result is `existing` itself when a
record already says the same about that sighting. Otherwise the sighting
leaves whichever record held it (records left empty, and failures at that
sighting, are dropped) and joins a record with an identical namespace, or
`new` is appended.
"""
function merge_observation(existing::Vector{CatalogRecord}, new::PkgNames)
    # As a catalog file's records are: folding them in one sighting at a time only appends.
    is_apart(record) = !any(sighting -> holds(record, sighting), new.at) &&
        !(record isa PkgNames && same_namespace(record, new))
    all(is_apart, existing) && return push!(copy(existing), new)
    foldl(new.at; init = existing) do records, sighting
        merge_single(records, with_sightings(new, [sighting]))
    end
end

merge_observation(existing::Vector{CatalogRecord}, new::PkgFailure) = merge_single(existing, new)

"""
    catalog_line(record) -> String

Serialise `record` to one tab-separated line, the inverse of
[`parse_catalog_line`](@ref). Sightings are written as `;`-separated groups
of `,`-separated versions (`-` for none) seen on the same Julia minors, each
followed by `@` and those minors as `+`-separated ranges, as in
`1.0.0,1.1.0@1.12-14;1.2.0@1.14`. Each name but a macro's follows its kind
(`?` if unknown); re-exported names follow a `/uuid/Name` token for their origin.

# Raises
`ArgumentError` if the id has no UUID or any name contains whitespace, since
the line could not be parsed back.
"""
function catalog_line(record::PkgNames)
    join((id_fields(record.id)..., sightings_field(record.at), "ok",
          name_list(record.exported, record.kinds), name_list(record.public, record.kinds), reexport_list(record)), '\t')
end

function catalog_line(record::PkgFailure)
    join((id_fields(record.id)..., sightings_field([record.at]), "failed", escape_message(record.message)), '\t')
end

"""
    parse_catalog_line(line) -> Union{CatalogRecord, Nothing}

Parse a line written by [`catalog_line`](@ref). Returns `nothing` for
malformed lines and for ids without a UUID.
"""
function parse_catalog_line(line::AbstractString)
    fields = split(line, '\t')
    length(fields) >= 5 || return nothing
    uuid = tryparse(Base.UUID, fields[1])
    (uuid === nothing || isempty(fields[2])) && return nothing
    id = Base.PkgId(uuid, String(fields[2]))
    at = @something(parse_sightings(fields[3]), return nothing)
    if fields[4] == "ok" && length(fields) == 7
        sets = (Set{Symbol}(), Set{Symbol}(), Set{Symbol}())
        kinds, origins = Dict{Symbol, Char}(), Dict{Symbol, Base.PkgId}()
        for (index, field) in enumerate(fields[5:7])
            origin = nothing
            for token in eachsplit(field, ' '; keepempty = false)
                if index == 3 && startswith(token, '/')
                    parts = split(token, '/')
                    length(parts) == 3 || return nothing
                    origin_uuid = if !isempty(parts[2]) @something(tryparse(Base.UUID, parts[2]), return nothing) end
                    origin = Base.PkgId(origin_uuid, String(parts[3]))
                    continue
                end
                kind = first(token)
                # A kind is one ASCII byte, so the name starts at index 2.
                name = if kind == '@'
                    Symbol(token)
                elseif ncodeunits(token) > 1 && (kind in NAME_KINDS || kind == '?')
                    Symbol(SubString(token, 2))
                else
                    return nothing
                end
                push!(sets[index], name)
                kind in NAME_KINDS && (kinds[name] = kind)
                origin === nothing || (origins[name] = origin)
            end
        end
        PkgNames(id, at, sets..., kinds, origins)
    elseif fields[4] == "failed" && length(at) == 1
        message = unescape_message(join(fields[5:end], '\t'))
        if message !== nothing PkgFailure(id, only(at), message) end
    end
end

# ── Helpers ──

function merge_single(existing::Vector{CatalogRecord}, new::CatalogRecord)
    sighting = observed_sighting(new)
    any(r -> holds(r, sighting) && same_claim(r, new), existing) && return existing
    merged = CatalogRecord[]
    for record in existing
        stripped = without_sighting(record, sighting)
        stripped === nothing || push!(merged, stripped)
    end
    twin = if new isa PkgNames findfirst(r -> r isa PkgNames && same_namespace(r, new), merged) end
    if twin === nothing
        push!(merged, new)
    else
        record = merged[twin]
        merged[twin] = with_sightings(record, sort!(vcat(record.at, new.at); by = sighting_order))
    end
    merged
end

same_namespace(a::PkgNames, b::PkgNames) =
    a.exported == b.exported && a.public == b.public && a.reexported == b.reexported && a.kinds == b.kinds &&
    a.origins == b.origins

with_sightings(record::PkgNames, at::Vector{Sighting}) =
    PkgNames(record.id, at, record.exported, record.public, record.reexported, record.kinds, record.origins)

same_claim(a::PkgNames, b::PkgNames) = same_namespace(a, b)
same_claim(a::PkgFailure, b::PkgFailure) = a.message == b.message
same_claim(::CatalogRecord, ::CatalogRecord) = false

observed_sighting(record::PkgNames) = only(record.at)
observed_sighting(record::PkgFailure) = record.at

holds(record::PkgNames, sighting::Sighting) = sighting in record.at
holds(record::PkgFailure, sighting::Sighting) = record.at == sighting

without_sighting(record::PkgFailure, sighting::Sighting) = if record.at != sighting record end

function without_sighting(record::PkgNames, sighting::Sighting)
    holds(record, sighting) || return record
    remaining = filter(!=(sighting), record.at)
    if !isempty(remaining) with_sightings(record, remaining) end
end

# No version sorts before any.
version_order(version::Union{VersionNumber, Nothing}) = (version !== nothing, something(version, v"0"))
sighting_order((; version, julia)::Sighting) = (julia, version_order(version))

minor_text(julia::VersionNumber) = "$(julia.major).$(julia.minor)"

# `at` is sorted, so each version's minors are too.
function sightings_field(at::Vector{Sighting})
    minors_of = Dict{Union{VersionNumber, Nothing}, Vector{VersionNumber}}()
    for (; version, julia) in at
        push!(get!(minors_of, version, VersionNumber[]), julia)
    end
    versions_on = Dict{Vector{VersionNumber}, Vector{Union{VersionNumber, Nothing}}}()
    for (version, minors) in minors_of
        push!(get!(versions_on, minors, Union{VersionNumber, Nothing}[]), version)
    end
    groups = map(sort!(collect(versions_on); by = first)) do (minors, versions)
        join((something(v, "-") for v in sort!(versions; by = version_order)), ',') * '@' * julia_ranges(minors)
    end
    join(groups, ';')
end

"Sorted Julia minors as `+`-separated runs of consecutive minors, as in `1.10+1.12-14`."
function julia_ranges(minors::Vector{VersionNumber})
    precedes(a, b) = a !== nothing && b !== nothing && a.major == b.major && a.minor + 1 == b.minor
    io = IOBuffer()
    for (i, minor) in enumerate(minors)
        previous, next = get(minors, i - 1, nothing), get(minors, i + 1, nothing)
        if !precedes(previous, minor)
            print(io, if i > 1 "+" else "" end, minor_text(minor))
        elseif !precedes(minor, next)
            print(io, '-', minor.minor)
        end
    end
    String(take!(io))
end

# `nothing` unless every group, version and Julia range is well formed.
function parse_sightings(field::AbstractString)
    at = Sighting[]
    for group in eachsplit(field, ';')
        parts = split(group, '@')
        length(parts) == 2 || return nothing
        versions_text, julias_text = parts
        minors = @something(parse_julia_ranges(julias_text), return nothing)
        for text in eachsplit(versions_text, ',')
            version = if text == "-" nothing else @something(tryparse(VersionNumber, text), return nothing) end
            append!(at, Sighting[(; version, julia) for julia in minors])
        end
    end
    if !isempty(at) sort!(unique!(at); by = sighting_order) end
end

function parse_julia_ranges(text::AbstractString)
    minors = VersionNumber[]
    for range in eachsplit(text, '+')
        bounds = @something(match(r"^(\d{1,4})\.(\d{1,4})(?:-(\d{1,4}))?$", range), return nothing)
        major, from = parse(Int, bounds[1]), parse(Int, bounds[2])
        to = if bounds[3] === nothing from else parse(Int, bounds[3]) end
        from <= to || return nothing
        append!(minors, VersionNumber(major, minor) for minor in from:to)
    end
    minors
end

function is_within(mod::Module, ancestor::Module)
    while mod !== ancestor
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
    true
end

function id_fields(id::Base.PkgId)
    id.uuid === nothing && throw(ArgumentError("cannot write catalog line for $(id.name): package id has no UUID"))
    any(isspace, id.name) && throw(ArgumentError("cannot write catalog line for package \"$(id.name)\": name contains whitespace"))
    (string(id.uuid), id.name)
end

function name_list(names::Set{Symbol}, kinds::Dict{Symbol, Char})
    strings = sort!(string.(names))
    any(s -> any(isspace, s), strings) &&
        throw(ArgumentError("cannot write catalog line: names $(filter(s -> any(isspace, s), strings)) contain whitespace"))
    join((if startswith(name, '@') name else get(kinds, Symbol(name), '?') * name end for name in strings), ' ')
end

"The re-exported names of `record`, those of known origin after a `/uuid/Name` token for it."
function reexport_list(record::PkgNames)
    by_origin = Dict{Union{Base.PkgId, Nothing}, Set{Symbol}}()
    for name in record.reexported
        push!(get!(by_origin, get(record.origins, name, nothing), Set{Symbol}()), name)
    end
    parts = String[]
    for origin in sort!(collect(keys(by_origin)); by = origin -> if origin === nothing "" else origin.name end)
        origin === nothing || push!(parts, "/$(something(origin.uuid, ""))/$(origin.name)")
        push!(parts, name_list(by_origin[origin], record.kinds))
    end
    join(parts, ' ')
end

escape_message(message::AbstractString) =
    replace(message, '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r")

# `nothing` on an unknown or dangling escape.
function unescape_message(text::AbstractString)
    out = IOBuffer()
    is_escaped = false
    for c in text
        if is_escaped
            write(out, if c == '\\' '\\' elseif c == 'n' '\n' elseif c == 'r' '\r' else return nothing end)
        elseif c != '\\'
            write(out, c)
        end
        is_escaped = !is_escaped && c == '\\'
    end
    if !is_escaped String(take!(out)) end
end
