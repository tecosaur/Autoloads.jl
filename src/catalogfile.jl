# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The on-disk catalog, shared by every Julia version: a format header, then one
# record per line. Writes hold a pidfile lock; reads take none and skip torn
# lines. Depends only on Base, for the indexer script.

const FILEWATCHING_ID = Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")
const LOCK_STALE_AGE_S = 60
const CATALOG_FORMAT = 1
const CATALOG_HEADER_PREFIX = "Autoloads catalog v"
const CATALOG_HEADER = CATALOG_HEADER_PREFIX * string(CATALOG_FORMAT)
const INDEXING_LOCK_SUFFIX = ".indexing-$(minortext(JULIA_MINOR))"

"""
    CatalogTooNew(path, format)

The catalog at `path` is in format `format`, newer than this Autoloads reads.
"""
struct CatalogTooNew <: Exception
    path::String
    format::Int
end

Base.showerror(io::IO, e::CatalogTooNew) =
    print(io, "The Autoloads catalog at ", e.path, " is in format v", e.format, ", newer than the v", CATALOG_FORMAT,
          " this version of Autoloads reads, so it is left untouched. Update Autoloads for Julia ",
          minortext(JULIA_MINOR), " (`pkg> up Autoloads` with the global environment active) to use it.")

"""
    readcatalog(path::AbstractString) -> Vector{CatalogRecord}

The records in `path`, read without locking, skipping malformed (e.g. torn)
lines. Like every catalog read and write, throws `CatalogTooNew` for a newer
format.
"""
readcatalog(path::AbstractString) = first(parsecatalogfile(path))

"""
    readhealedcatalog(path::AbstractString) -> Vector{CatalogRecord}

`readcatalog`, also removing malformed lines from the file under the lock.
"""
function readhealedcatalog(path::AbstractString)
    records, malformed = parsecatalogfile(path)
    malformed == 0 && return records
    try
        # Under the lock, a line still being appended is not taken for torn.
        withfilelock(path) do
            lockedrecords, lockedmalformed = parsecatalogfile(path)
            if lockedmalformed > 0
                rewritecatalog(path, lockedrecords)
                @warn "Removed $lockedmalformed catalog lines that were malformed or of another format" path
            end
            lockedrecords
        end
    catch err
        err isa CatalogTooNew && rethrow()
        @warn "Skipped $malformed malformed catalog lines, which could not be removed" path exception = err maxlog = 1
        records
    end
end

"""
    withfilelock(f, path::AbstractString)

Run `f()` holding the lock for `path`. Locks of dead processes, or older than
$(LOCK_STALE_AGE_S) s, are stolen.
"""
function withfilelock(f, path::AbstractString)
    mkpath(dirname(path))
    pidfile = Base.require(FILEWATCHING_ID).Pidfile
    Base.invokelatest(pidfile.mkpidlock, f, path * ".pid"; stale_age = LOCK_STALE_AGE_S)
end

"""
    writecatalog!(path::AbstractString, observations::Vector{CatalogRecord}) -> Bool

Fold `observations` into the catalog at `path`, under the lock and against its
current contents. Returns whether the file was written.
"""
function writecatalog!(path::AbstractString, observations::Vector{CatalogRecord})
    withfilelock(path) do
        parsed, malformed = parsecatalogfile(path)
        filerecords = Dict{Base.PkgId, Vector{CatalogRecord}}()
        foreach(r -> push!(get!(filerecords, r.id, CatalogRecord[]), r), parsed)
        merged = copy(filerecords)
        for new in observations, sighting in new.at
            merged[new.id] = mergesighting(get(merged, new.id, CatalogRecord[]), new, sighting)
        end
        changed = [id for (id, records) in merged if get(filerecords, id, nothing) != records]
        isempty(changed) && malformed == 0 && return false
        if malformed > 0 || any(in(keys(filerecords)), changed)
            rewritecatalog(path, Iterators.flatten(values(merged)))
            malformed > 0 && @warn "Removed $malformed catalog lines that were malformed or of another format" path
        else
            appendcatalog(path, [r for id in changed for r in merged[id]])
        end
        true
    end
end

function clearfailures!(path::AbstractString, ids)
    iscleared(r) = r isa PkgFailure && r.id in ids
    any(iscleared, readcatalog(path)) || return false
    withfilelock(path) do
        records = first(parsecatalogfile(path))
        any(iscleared, records) || return false
        rewritecatalog(path, filter(!iscleared, records))
        true
    end
end

# Reading and writing lines

function parsecatalogfile(path::AbstractString)
    records = CatalogRecord[]
    malformed = 0
    isfile(path) || return records, malformed
    hasheader = false
    open(path) do io
        for (i, line) in enumerate(eachline(io))
            if i == 1
                format = something(if startswith(line, CATALOG_HEADER_PREFIX) tryparse(Int, chopprefix(line, CATALOG_HEADER_PREFIX)) end, 0)
                format > CATALOG_FORMAT && throw(CatalogTooNew(path, format))
                (hasheader = format == CATALOG_FORMAT) && continue
            end
            isempty(line) && continue
            record = if hasheader parsecatalogline(line) end
            if record === nothing
                malformed += 1
            else
                push!(records, record)
            end
        end
    end
    records, malformed
end

# Lines are serialised first so a rejected record leaves the file untouched.
# One `write` per line so O_APPEND keeps each line contiguous.
function appendcatalog(path, records)
    lines = [catalogline(r) * "\n" for r in records]
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_APPEND | Base.Filesystem.JL_O_CREAT
    file = Base.Filesystem.open(path, flags, 0o644)
    try
        istorn = filesize(path) > 0 && open(io -> (seekend(io); skip(io, -1); read(io, UInt8)), path) != UInt8('\n')
        istorn && write(file, "\n")
        filesize(path) == 0 && write(file, CATALOG_HEADER * "\n")
        foreach(line -> write(file, line), lines)
    finally
        close(file)
    end
end

# Lines are sorted so a rewrite is deterministic.
function rewritecatalog(path::AbstractString, records)
    lines = sort!(String[catalogline(r) for r in records])
    writeatomically(path, join(pushfirst!(lines, CATALOG_HEADER), '\n') * '\n')
end

# Copied in scripts/projectfiles.jl.
function writeatomically(path::AbstractString, content)
    tmp = path * ".tmp-$(getpid())"
    try
        write(tmp, content)
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
end
