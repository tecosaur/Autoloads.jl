# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Catalog records and their line format. Depends only on Base, for the indexer script.

# What a name is bound to: a module, function, type or other value. A macro's name says as much.
const NAME_KINDS = ".+:="

const JULIA_MINOR = VersionNumber(VERSION.major, VERSION.minor)

# `version` is `nothing` for a built-in, and `julia` a minor version.
const Sighting = @NamedTuple{version::Union{VersionNumber, Nothing}, julia::VersionNumber}

"""
    PkgNames(id, at, exported, public, reexported; kinds = Dict(), origins = Dict())

One namespace of package `id`, seen at each of `at` (sorted, nonempty, and
disjoint across the package's records). `exported` includes the module's own
name; where known, `kinds` maps names to `NAME_KINDS`, and `origins`
re-exported names to their owner.
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

struct PkgFailure
    id::Base.PkgId
    at::Vector{Sighting}
    message::String
end

const CatalogRecord = Union{PkgNames, PkgFailure}

const INTERRUPTED_EXIT_CODE = 130  # 128 + SIGINT, as shells report an interrupted process

isinterrupt(err) = err isa InterruptException ||
    (isdefined(Base, :CancellationRequest) && err isa Base.CancellationRequest) ||
    (err isa Union{Base.InitError, LoadError} && isinterrupt(err.error))

Base.:(==)(a::R, b::R) where {R <: CatalogRecord} = a.id == b.id && a.at == b.at && sameclaim(a, b)
Base.hash(r::CatalogRecord, h::UInt) = hash(r.at, hash(r.id, h))

"""
    extractnames(mod::Module, id::Base.PkgId = Base.PkgId(mod)) -> PkgNames

The namespace `mod` offers, seen at its `pkgversion` on this Julia. Names
owned by `Base` or `Core` are skipped unless `mod` is part of `Base`, as are
undefined bindings and names containing whitespace.
"""
function extractnames(mod::Module, id::Base.PkgId = Base.PkgId(mod))
    function iswithin(inner::Module, ancestor::Module)
        while inner !== ancestor
            parent = parentmodule(inner)
            parent === inner && return false
            inner = parent
        end
        true
    end
    isbuiltin = iswithin(mod, Base)
    exported = Set{Symbol}((nameof(mod),))
    public = Set{Symbol}()
    reexported = Set{Symbol}()
    kinds = Dict{Symbol, Char}(nameof(mod) => '.')
    origins = Dict{Symbol, Base.PkgId}()
    for name in names(mod)
        isdefined(mod, name) && !any(isspace, string(name)) || continue
        owner = Base.binding_module(mod, name)
        isexport = Base.isexported(mod, name)
        iscore = owner === Base || owner === Core
        if iswithin(owner, mod) || (isbuiltin && iscore)
            push!(if isexport exported else public end, name)
        elseif isexport && !iscore
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
    catalogline(record::PkgNames) -> String

Serialise `record` as one tab-separated line. Sightings are written as in
`1.0.0,1.1.0@1.12-14;1.2.0@1.14`, names after their kind (`?` if unknown), and
re-exports after a `/uuid/Name` token for their origin. Throws `ArgumentError`
for an id without a UUID or a name containing whitespace.
"""
function catalogline(record::PkgNames)
    join((idfields(record.id)..., sightingsfield(record.at), "ok",
          namelist(record.exported, record.kinds), namelist(record.public, record.kinds), reexportlist(record)), '\t')
end

function catalogline(record::PkgFailure)
    join((idfields(record.id)..., sightingsfield(record.at), "failed", escapemessage(record.message)), '\t')
end

function parsecatalogline(line::AbstractString)
    fields = split(line, '\t')
    length(fields) >= 5 || return nothing
    uuid = tryparse(Base.UUID, fields[1])
    (uuid === nothing || isempty(fields[2])) && return nothing
    id = Base.PkgId(uuid, String(fields[2]))
    at = @something(parsesightings(fields[3]), return nothing)
    if fields[4] == "ok" && length(fields) == 7
        sets = (Set{Symbol}(), Set{Symbol}(), Set{Symbol}())
        kinds, origins = Dict{Symbol, Char}(), Dict{Symbol, Base.PkgId}()
        for (index, field) in enumerate(fields[5:7])
            origin = nothing
            for token in eachsplit(field, ' '; keepempty = false)
                if index == 3 && startswith(token, '/')
                    parts = split(token, '/')
                    length(parts) == 3 || return nothing
                    originuuid = if !isempty(parts[2]) @something(tryparse(Base.UUID, parts[2]), return nothing) end
                    origin = Base.PkgId(originuuid, String(parts[3]))
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
    elseif fields[4] == "failed"
        message = unescapemessage(join(fields[5:end], '\t'))
        if message !== nothing PkgFailure(id, at, message) end
    end
end

# Merging and serialisation

function mergesighting(existing::Vector{CatalogRecord}, new::CatalogRecord, sighting::Sighting)
    any(r -> sighting in r.at && sameclaim(r, new), existing) && return existing
    merged = CatalogRecord[]
    for record in existing
        rest = filter(!=(sighting), record.at)
        isempty(rest) || push!(merged, withsightings(record, rest))
    end
    twin = findfirst(r -> sameclaim(r, new), merged)
    if twin === nothing
        push!(merged, withsightings(new, [sighting]))
    else
        merged[twin] = withsightings(merged[twin], sort!(push!(copy(merged[twin].at), sighting); by = sightingorder))
    end
    merged
end

sameclaim(a::PkgNames, b::PkgNames) =
    a.exported == b.exported && a.public == b.public && a.reexported == b.reexported && a.kinds == b.kinds &&
    a.origins == b.origins
sameclaim(a::PkgFailure, b::PkgFailure) = a.message == b.message
sameclaim(::CatalogRecord, ::CatalogRecord) = false

withsightings(r::PkgNames, at::Vector{Sighting}) = PkgNames(r.id, at, r.exported, r.public, r.reexported, r.kinds, r.origins)
withsightings(r::PkgFailure, at::Vector{Sighting}) = PkgFailure(r.id, at, r.message)

# No version sorts before any.
versionorder(version::Union{VersionNumber, Nothing}) = (version !== nothing, something(version, v"0"))
sightingorder((; version, julia)::Sighting) = (julia, versionorder(version))

minortext(julia::VersionNumber) = "$(julia.major).$(julia.minor)"

# `at` is sorted, so each version's minors are too.
function sightingsfield(at::Vector{Sighting})
    minorsof = Dict{Union{VersionNumber, Nothing}, Vector{VersionNumber}}()
    for (; version, julia) in at
        push!(get!(minorsof, version, VersionNumber[]), julia)
    end
    versionson = Dict{Vector{VersionNumber}, Vector{Union{VersionNumber, Nothing}}}()
    for (version, minors) in minorsof
        push!(get!(versionson, minors, Union{VersionNumber, Nothing}[]), version)
    end
    groups = map(sort!(collect(versionson); by = first)) do (minors, versions)
        join((something(v, "-") for v in sort!(versions; by = versionorder)), ',') * '@' * juliaranges(minors)
    end
    join(groups, ';')
end

function juliaranges(minors::Vector{VersionNumber})
    precedes(a, b) = a !== nothing && b !== nothing && a.major == b.major && a.minor + 1 == b.minor
    io = IOBuffer()
    for (i, minor) in enumerate(minors)
        previous, next = get(minors, i - 1, nothing), get(minors, i + 1, nothing)
        if !precedes(previous, minor)
            print(io, if i > 1 "+" else "" end, minortext(minor))
        elseif !precedes(minor, next)
            print(io, '-', minor.minor)
        end
    end
    String(take!(io))
end

function parsesightings(field::AbstractString)
    at = Sighting[]
    for group in eachsplit(field, ';')
        parts = split(group, '@')
        length(parts) == 2 || return nothing
        versionstext, juliastext = parts
        minors = @something(parsejuliaranges(juliastext), return nothing)
        for text in eachsplit(versionstext, ',')
            version = if text == "-" nothing else @something(tryparse(VersionNumber, text), return nothing) end
            append!(at, Sighting[(; version, julia) for julia in minors])
        end
    end
    if !isempty(at) sort!(unique!(at); by = sightingorder) end
end

function parsejuliaranges(text::AbstractString)
    minors = VersionNumber[]
    for range in eachsplit(text, '+')
        dot = @something(findfirst('.', range), return nothing)
        major = @something(tryparse(UInt16, range[begin:prevind(range, dot)]), return nothing)
        span = split(range[nextind(range, dot):end], '-')
        from, to = tryparse(UInt16, first(span)), tryparse(UInt16, last(span))
        length(span) <= 2 && from !== nothing && to !== nothing && from <= to || return nothing
        append!(minors, VersionNumber(major, minor) for minor in from:to)
    end
    minors
end

function idfields(id::Base.PkgId)
    id.uuid === nothing && throw(ArgumentError("cannot write catalog line for $(id.name): package id has no UUID"))
    any(isspace, id.name) && throw(ArgumentError("cannot write catalog line for package \"$(id.name)\": name contains whitespace"))
    (string(id.uuid), id.name)
end

function namelist(names::Set{Symbol}, kinds::Dict{Symbol, Char})
    strings = sort!(string.(names))
    spaced = filter(s -> any(isspace, s), strings)
    isempty(spaced) || throw(ArgumentError("cannot write catalog line: names $spaced contain whitespace"))
    join((if startswith(name, '@') name else get(kinds, Symbol(name), '?') * name end for name in strings), ' ')
end

function reexportlist(record::PkgNames)
    byorigin = Dict{Union{Base.PkgId, Nothing}, Set{Symbol}}()
    for name in record.reexported
        push!(get!(byorigin, get(record.origins, name, nothing), Set{Symbol}()), name)
    end
    parts = String[]
    for origin in sort!(collect(keys(byorigin)); by = origin -> if origin === nothing "" else origin.name end)
        origin === nothing || push!(parts, "/$(something(origin.uuid, ""))/$(origin.name)")
        push!(parts, namelist(byorigin[origin], record.kinds))
    end
    join(parts, ' ')
end

escapemessage(message::AbstractString) =
    replace(message, '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r")

function unescapemessage(text::AbstractString)
    out = IOBuffer()
    escaped = false
    for c in text
        if escaped
            write(out, if c == '\\' '\\' elseif c == 'n' '\n' elseif c == 'r' '\r' else return nothing end)
        elseif c != '\\'
            write(out, c)
        end
        escaped = !escaped && c == '\\'
    end
    if !escaped String(take!(out)) end
end
