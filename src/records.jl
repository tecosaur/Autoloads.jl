# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Catalog records: what the package catalog knows about each package's
# namespace, and their line-oriented serialisation. Depends only on Base so
# that the standalone indexer script can include it.

"""
    PkgNames(id, versions, exported, public, reexported)

One namespace offered by package `id`, and the exact sorted `versions`
offering it (empty for built-in modules). `exported` always includes the
module's own name. Records for one `id` have disjoint `versions`.
"""
struct PkgNames
    id::Base.PkgId
    versions::Vector{VersionNumber}
    exported::Set{Symbol}
    public::Set{Symbol}
    reexported::Set{Symbol}
end

"""
    PkgFailure(id, version, message)

Package `id` could not be loaded at `version` (`nothing` if unknown).
"""
struct PkgFailure
    id::Base.PkgId
    version::Union{VersionNumber, Nothing}
    message::String
end

const CatalogRecord = Union{PkgNames, PkgFailure}

"Exit code of an indexer subprocess that was interrupted (shell convention, 128 + SIGINT)."
const INTERRUPTED_EXIT_CODE = 130

Base.:(==)(a::PkgNames, b::PkgNames) =
    a.id == b.id && a.versions == b.versions && same_namespace(a, b)

Base.:(==)(a::PkgFailure, b::PkgFailure) =
    a.id == b.id && a.version == b.version && a.message == b.message

Base.hash(r::PkgNames, h::UInt) =
    hash((r.id, r.versions, r.exported, r.public, r.reexported), hash(:PkgNames, h))

Base.hash(r::PkgFailure, h::UInt) =
    hash((r.id, r.version, r.message), hash(:PkgFailure, h))

"""
    extract_names(mod, id = Base.PkgId(mod)) -> PkgNames

Collect the namespace `mod` offers. Names defined in `mod` or its submodules
are `exported` or `public`; names exported from other packages are
`reexported`; names owned by `Base`/`Core` are skipped unless `mod` is itself
part of `Base`. Undefined bindings and names containing whitespace are skipped.

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
    for name in names(mod)
        isdefined(mod, name) && !any(isspace, string(name)) || continue
        owner = Base.binding_module(mod, name)
        is_exported = Base.isexported(mod, name)
        is_core = owner === Base || owner === Core
        if is_within(owner, mod) || (is_builtin && is_core)
            push!(is_exported ? exported : public, name)
        elseif is_exported && !is_core
            push!(reexported, name)
        end
    end
    version = pkgversion(mod)
    PkgNames(id, version === nothing ? VersionNumber[] : [version], exported, public, reexported)
end

"""
    merge_observation(existing, new) -> Vector{CatalogRecord}

Return the records for one package after observing `new`, a [`PkgNames`](@ref)
or a [`PkgFailure`](@ref). A multi-version `PkgNames` is observed one version
at a time, in order. The result is `existing` itself
when a record already says the same about that version. Otherwise the version
leaves whichever record held it (records left empty, and failures at that
version, are dropped) and joins a record with an identical namespace, or
`new` is appended.
"""
function merge_observation(existing::Vector{CatalogRecord}, new::PkgNames)
    length(new.versions) > 1 || return merge_single(existing, new)
    foldl(new.versions; init = existing) do records, version
        merge_single(records, PkgNames(new.id, [version], new.exported, new.public, new.reexported))
    end
end

merge_observation(existing::Vector{CatalogRecord}, new::PkgFailure) = merge_single(existing, new)

"""
    catalog_line(record) -> String

Serialise `record` to one tab-separated line, the inverse of
[`parse_catalog_line`](@ref).

# Raises
`ArgumentError` if the id has no UUID or any name contains whitespace, since
the line could not be parsed back.
"""
function catalog_line(record::PkgNames)
    versions = isempty(record.versions) ? "-" : join(record.versions, ',')
    join((id_fields(record.id)..., versions, "ok",
          name_list(record.exported), name_list(record.public), name_list(record.reexported)), '\t')
end

function catalog_line(record::PkgFailure)
    version = record.version === nothing ? "-" : string(record.version)
    join((id_fields(record.id)..., version, "failed", escape_message(record.message)), '\t')
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
    if fields[4] == "ok" && length(fields) == 7
        versions = parse_versions(fields[3])
        versions === nothing && return nothing
        PkgNames(id, versions, (Set{Symbol}(Symbol.(split(f, ' '; keepempty = false))) for f in fields[5:7])...)
    elseif fields[4] == "failed"
        version = fields[3] == "-" ? nothing : tryparse(VersionNumber, fields[3])
        message = unescape_message(join(fields[5:end], '\t'))
        (version === nothing && fields[3] != "-") || message === nothing ? nothing : PkgFailure(id, version, message)
    end
end

# ── Helpers ──

function merge_single(existing::Vector{CatalogRecord}, new::CatalogRecord)
    version = observed_version(new)
    any(r -> holds_version(r, version) && same_claim(r, new), existing) && return existing
    merged = CatalogRecord[]
    for record in existing
        stripped = without_version(record, version)
        stripped === nothing || push!(merged, stripped)
    end
    twin = new isa PkgNames ? findfirst(r -> r isa PkgNames && same_namespace(r, new), merged) : nothing
    if twin === nothing
        push!(merged, new)
    else
        record = merged[twin]
        merged[twin] = PkgNames(record.id, sort!(vcat(record.versions, new.versions)),
                                record.exported, record.public, record.reexported)
    end
    merged
end

same_namespace(a::PkgNames, b::PkgNames) =
    a.exported == b.exported && a.public == b.public && a.reexported == b.reexported

same_claim(a::PkgNames, b::PkgNames) = same_namespace(a, b)
same_claim(a::PkgFailure, b::PkgFailure) = a.message == b.message
same_claim(::CatalogRecord, ::CatalogRecord) = false

observed_version(record::PkgNames) = isempty(record.versions) ? nothing : only(record.versions)
observed_version(record::PkgFailure) = record.version

# A built-in's namespace is held by the `nothing` version.
holds_version(record::PkgNames, version) = version === nothing ? isempty(record.versions) : version in record.versions
holds_version(record::PkgFailure, version) = record.version == version

without_version(record::PkgFailure, version) = record.version == version ? nothing : record

function without_version(record::PkgNames, version)
    holds_version(record, version) || return record
    remaining = filter(!=(version), record.versions)
    isempty(remaining) ? nothing : PkgNames(record.id, remaining, record.exported, record.public, record.reexported)
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

function name_list(names::Set{Symbol})
    strings = sort!(string.(names))
    any(s -> any(isspace, s), strings) &&
        throw(ArgumentError("cannot write catalog line: names $(filter(s -> any(isspace, s), strings)) contain whitespace"))
    join(strings, ' ')
end

function parse_versions(field::AbstractString)
    field == "-" && return VersionNumber[]
    versions = tryparse.(VersionNumber, split(field, ','))
    any(isnothing, versions) ? nothing : versions
end

escape_message(message::AbstractString) =
    replace(message, '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r")

# `nothing` on an unknown or dangling escape.
function unescape_message(text::AbstractString)
    out = IOBuffer()
    chars = Iterators.Stateful(text)
    for c in chars
        if c != '\\'
            write(out, c)
        else
            escaped = isempty(chars) ? nothing : popfirst!(chars)
            escaped === '\\' ? write(out, '\\') :
                escaped === 'n' ? write(out, '\n') :
                escaped === 'r' ? write(out, '\r') : return nothing
        end
    end
    String(take!(out))
end
