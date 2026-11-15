# The on-disk catalog: one record per line. Reads take no lock and skip torn
# lines; writes are rare, serialised by a pidfile lock, and never lose another
# process's write. Depends only on Base (plus FileWatching, required lazily) so
# that the standalone indexer script can include it after `records.jl`.

const FILEWATCHING_ID = Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")
const LOCK_STALE_AGE_S = 60

"""
    read_catalog(path) -> Vector{CatalogRecord}

Read the records in `path`, in file order, without locking. A missing file
gives no records; malformed (e.g. torn) lines are skipped with one warning
giving their count.
"""
function read_catalog(path::AbstractString)
    isfile(path) || return CatalogRecord[]
    records = CatalogRecord[]
    malformed = 0
    for line in eachline(path)
        isempty(line) && continue
        record = parse_catalog_line(line)
        record === nothing ? (malformed += 1) : push!(records, record)
    end
    malformed > 0 && @warn "Skipped $malformed malformed catalog lines" path
    records
end

"""
    with_catalog_lock(f, path)

Run `f()` holding the exclusive lock for the catalog at `path`, and return its
result. Locks left by dead processes, or older than $(LOCK_STALE_AGE_S) s, are stolen.
"""
function with_catalog_lock(f, path::AbstractString)
    mkpath(dirname(path))
    pidfile = Base.require(FILEWATCHING_ID).Pidfile
    Base.invokelatest(pidfile.mkpidlock, f, path * ".pid"; stale_age = LOCK_STALE_AGE_S)
end

"""
    write_catalog_changes!(path, observations) -> Bool

Fold `observations` into the catalog at `path` with [`merge_observation`](@ref),
under the catalog lock and against the file's current contents. Returns
whether the file was written: nothing is written when no record changes, new
ids are appended, and any other change rewrites the file atomically.
"""
function write_catalog_changes!(path::AbstractString, observations::Vector{CatalogRecord})
    with_catalog_lock(path) do
        file_records = group_by_id(read_catalog(path))
        merged = copy(file_records)
        for observation in observations
            merged[observation.id] = merge_observation(get(merged, observation.id, CatalogRecord[]), observation)
        end
        changed = [id for (id, records) in merged if get(file_records, id, nothing) != records]
        isempty(changed) && return false
        if any(in(keys(file_records)), changed)
            rewrite_catalog(path, merged)
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
    with_catalog_lock(path) do
        records = read_catalog(path)
        any(is_cleared, records) || return false
        rewrite_catalog(path, group_by_id(filter(!is_cleared, records)))
        true
    end
end

# ── Helpers ──

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
        write(tmp, join(lines, '\n') * '\n')
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
end
