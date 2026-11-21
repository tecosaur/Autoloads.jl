# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The indexer subprocess, started by `startindexing!` as
#
#     julia --project=<env> index.jl <lazy|background> <catalog path> <uuid=name=version>...
#
# (`-` for an unknown version). Reports `indexing <uuid>` and `indexed <uuid>`
# around each package, and `precompiling start` and `done` around precompiling,
# on stdout; logs go to stderr.
# Exits 0 at once if another indexer of this Julia version holds the lock, and
# with INTERRUPTED_EXIT_CODE when interrupted.

include(joinpath(@__DIR__, "..", "records.jl"))
include(joinpath(@__DIR__, "..", "catalogfile.jl"))

const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const MAX_MESSAGE_CHARS = 2000
const Pidfile = Base.require(FILEWATCHING_ID).Pidfile

function main(args)
    policy, path = args[1], args[2]
    packages = map(args[3:end]) do entry
        uuid, name, version = split(entry, '='; limit = 3)
        Base.PkgId(Base.UUID(uuid), String(name)) => if version != "-" VersionNumber(version) end
    end
    mkpath(dirname(path))
    lock = Pidfile.trymkpidlock(path * INDEXING_LOCK_SUFFIX; stale_age = LOCK_STALE_AGE_S)
    lock === false && return
    try
        policy == "background" && precompilepackages(packages)
        for (id, version) in packages
            indexpackage(path, id, version)
        end
    finally
        close(lock)
    end
end

# Utility functions

# The supervisor may have exited with its REPL.
function report(line)
    try
        println(stdout, line)
        flush(stdout)
    catch err
        err isa Base.IOError || rethrow()
        redirect_stdout(devnull)
    end
end

# Precompile failures surface again, with context, when the package is loaded.
function precompilepackages(packages)
    names = [id.name for (id, _) in packages if !isfile(joinpath(Sys.STDLIB, id.name, "Project.toml"))]
    isempty(names) && return
    report("precompiling start")
    try
        Base.invokelatest(Base.require(PKG_ID).precompile, names)
    catch err
        isinterrupt(err) && rethrow()
        @error "Precompiling $(join(names, ", ")) failed; indexing anyway" exception = (err, catch_backtrace())
    end
    report("precompiling done")
end

# Names are recorded at the requested (manifest) version, the one the catalog
# will be asked about, rather than `pkgversion`.
function indexpackage(path, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    report("indexing $(id.uuid)")
    at = Sighting[(; version, julia = JULIA_MINOR)]
    record = try
        names = Base.invokelatest(extractnames, Base.require(id), id)
        if version === nothing names else withsightings(names, at) end
    catch err
        isinterrupt(err) && rethrow()
        @error "Failed to load $(id.name) for indexing" exception = (err, catch_backtrace())
        PkgFailure(id, at, first(sprint(showerror, err), MAX_MESSAGE_CHARS))
    end
    writecatalog!(path, CatalogRecord[record])
    report("indexed $(id.uuid)")
end

# Loading wraps an interrupt in `LoadError`/`InitError`.
isinterrupt(err) =
    err isa InterruptException || ((err isa LoadError || err isa InitError) && isinterrupt(err.error))

# ---------

# Julia 1.12.7 segfaults on SIGINT with this set (exit 0, signal 11), so an
# interrupt there is recorded as a crash of the package in progress.
Base.exit_on_sigint(false)
try
    main(ARGS)
catch err
    isinterrupt(err) || rethrow()
    exit(INTERRUPTED_EXIT_CODE)
end
