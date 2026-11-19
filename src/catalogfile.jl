# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The on-disk catalog, shared by every Julia version: a header line naming the
# format, then one record per line. Reads take no lock and skip torn lines, and
# every line of a file in an older format; the session worker's reads and all
# writes remove them. A file in a newer format is neither read nor written.
# Writes are rare, serialised by a pidfile lock, and never lose another
# process's write. Depends only on Base (plus FileWatching, required lazily)
# so that the standalone indexer script can include it after `records.jl`.

const FILEWATCHING_ID = Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")
const LOCK_STALE_AGE_S = 60
const CATALOG_FORMAT = 1
const CATALOG_HEADER = "Autoloads catalog v$CATALOG_FORMAT"
# Appended to the catalog path for the lock of this Julia version's indexer.
const INDEXING_LOCK_SUFFIX = ".indexing-$(minor_text(JULIA_MINOR))"

"""
    CatalogTooNew(path, format)

The catalog at `path` is in format `format`, newer than this Autoloads
reads, so it is left untouched.
"""
struct CatalogTooNew <: Exception
    path::String
    format::Int
end

Base.showerror(io::IO, e::CatalogTooNew) =
    print(io, "The Autoloads catalog at ", e.path, " is in format v", e.format, ", newer than the v", CATALOG_FORMAT,
          " this version of Autoloads reads, so it is left untouched. Update Autoloads for Julia ",
          minor_text(JULIA_MINOR), " (`pkg> up Autoloads` with the global environment active) to use it.")

"""
    read_catalog(path) -> Vector{CatalogRecord}

Read the records in `path`, in file order, without locking. A missing file
gives no records; malformed (e.g. torn) lines are skipped silently (see
[`read_healed_catalog`](@ref)).

Raises [`CatalogTooNew`](@ref) for a file in a newer format, as do all the
other catalog reads and writes.
"""
read_catalog(path::AbstractString) = first(parse_catalog_file(path))

"""
    read_healed_catalog(path) -> Vector{CatalogRecord}

[`read_catalog`](@ref), but malformed lines are removed from the file under
the catalog lock, with one warning giving their count; if they cannot be
removed, that is warned of once per session instead. For the reader that
owns the catalog (the session worker): it may wait for the lock.
"""
function read_healed_catalog(path::AbstractString)
    records, malformed = parse_catalog_file(path)
    malformed == 0 && return records
    try
        # Under the lock, a line still being appended is not taken for torn.
        with_file_lock(path) do
            locked_records, locked_malformed = parse_catalog_file(path)
            if locked_malformed > 0
                rewrite_catalog(path, group_by_id(locked_records))
                @warn "Removed $locked_malformed catalog lines that were malformed or of another format" path
            end
            locked_records
        end
    catch err
        err isa CatalogTooNew && rethrow()
        @warn "Skipped $malformed malformed catalog lines, which could not be removed" path exception = err maxlog = 1
        records
    end
end

"""
    with_file_lock(f, path)

Run `f()` holding the exclusive lock for the file at `path`, and return its
result. Locks left by dead processes, or older than $(LOCK_STALE_AGE_S) s, are stolen.
"""
function with_file_lock(f, path::AbstractString)
    mkpath(dirname(path))
    pidfile = Base.require(FILEWATCHING_ID).Pidfile
    Base.invokelatest(pidfile.mkpidlock, f, path * ".pid"; stale_age = LOCK_STALE_AGE_S)
end

"""
    write_catalog_changes!(path, observations) -> Bool

Fold `observations` into the catalog at `path` with [`merge_observation`](@ref),
under the catalog lock and against the file's current contents. Returns
whether the file was written: nothing is written when no record changes, new
ids are appended, and any other change rewrites the file atomically, as does
removing malformed lines (with a warning).
"""
function write_catalog_changes!(path::AbstractString, observations::Vector{CatalogRecord})
    with_file_lock(path) do
        parsed, malformed = parse_catalog_file(path)
        file_records = group_by_id(parsed)
        merged = copy(file_records)
        for observation in observations
            merged[observation.id] = merge_observation(get(merged, observation.id, CatalogRecord[]), observation)
        end
        changed = [id for (id, records) in merged if get(file_records, id, nothing) != records]
        isempty(changed) && malformed == 0 && return false
        if malformed > 0 || any(in(keys(file_records)), changed)
            rewrite_catalog(path, merged)
            malformed > 0 && @warn "Removed $malformed catalog lines that were malformed or of another format" path
        else
            append_catalog(path, [r for id in changed for r in merged[id]])
        end
        true
    end
end

"""
    clear_failures!(path, ids) -> Bool

Drop every [`PkgFailure`](@ref) of the packages `ids` from the catalog at
`path`, so they are indexed again, under the catalog lock. Returns whether
the file was written: nothing is written when it has no such failure.
"""
function clear_failures!(path::AbstractString, ids)
    is_cleared(r) = r isa PkgFailure && r.id in ids
    any(is_cleared, read_catalog(path)) || return false
    with_file_lock(path) do
        records = first(parse_catalog_file(path))
        any(is_cleared, records) || return false
        rewrite_catalog(path, group_by_id(filter(!is_cleared, records)))
        true
    end
end

# ── Helpers ──

"""
The records in `path` (none if it is missing) and the number of malformed
lines: all of them when the file does not start with [`CATALOG_HEADER`](@ref).
Throws [`CatalogTooNew`](@ref) if it starts with a newer format's header.
"""
function parse_catalog_file(path::AbstractString)
    records = CatalogRecord[]
    malformed = 0
    isfile(path) || return records, malformed
    has_header = false
    for (i, line) in enumerate(eachline(path))
        if i == 1
            header = match(r"^Autoloads catalog v(\d{1,9})$", line)
            format = if header === nothing 0 else parse(Int, header[1]) end
            format > CATALOG_FORMAT && throw(CatalogTooNew(path, format))
            (has_header = format == CATALOG_FORMAT) && continue
        end
        isempty(line) && continue
        record = if has_header parse_catalog_line(line) end
        if record === nothing
            malformed += 1
        else
            push!(records, record)
        end
    end
    records, malformed
end

group_by_id(records) = foldl((groups, r) -> (push!(get!(groups, r.id, CatalogRecord[]), r); groups),
                             records; init = Dict{Base.PkgId, Vector{CatalogRecord}}())

# Lines are serialised first so a rejected record leaves the file untouched.
# One `write` per line so O_APPEND keeps each line contiguous.
function append_catalog(path, records)
    lines = [catalog_line(r) * "\n" for r in records]
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_APPEND | Base.Filesystem.JL_O_CREAT
    file = Base.Filesystem.open(path, flags, 0o644)
    try
        is_torn = filesize(path) > 0 && open(io -> (seekend(io); skip(io, -1); read(io, UInt8)), path) != UInt8('\n')
        is_torn && write(file, "\n")
        filesize(path) == 0 && write(file, CATALOG_HEADER * "\n")
        foreach(line -> write(file, line), lines)
    finally
        close(file)
    end
end

# Lines sort within and across ids so a rewrite is deterministic.
function rewrite_catalog(path, groups)
    lines = sort!([catalog_line(r) for records in values(groups) for r in records])
    tmp = path * ".tmp-$(getpid())"
    try
        write(tmp, join([CATALOG_HEADER; lines], '\n') * '\n')
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
end
