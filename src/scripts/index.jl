# Indexer subprocess: load each requested package and record its namespace,
# or why it failed to load, in the catalog. Started by `start_indexing!` as
#
#     julia --project=<env> index.jl <lazy|background> <catalog path> <uuid=name=version>...
#
# with `-` for an unknown version. Progress goes to stdout for the supervisor:
# `indexing <uuid>` before loading each package, and `precompiling start` /
# `precompiling done` around the precompile phase. If another indexer holds
# the catalog's `.indexing` lock, exits 0 without printing any of these.
# Interruption exits with INTERRUPTED_EXIT_CODE so the supervisor can tell it
# from a crash.

include(joinpath(@__DIR__, "..", "records.jl"))
include(joinpath(@__DIR__, "..", "catalogfile.jl"))

const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const MAX_MESSAGE_CHARS = 2000
const Pidfile = Base.require(FILEWATCHING_ID).Pidfile

function main(args)
    policy, path = args[1], args[2]
    packages = parse_entry.(args[3:end])
    mkpath(dirname(path))
    lock = Pidfile.trymkpidlock(path * ".indexing"; stale_age = LOCK_STALE_AGE_S)
    lock === false && return
    try
        policy == "background" && precompile_packages(packages)
        for (id, version) in packages
            index_package(path, id, version)
        end
    finally
        close(lock)
    end
end

# ── Helpers ──

function parse_entry(entry::AbstractString)
    uuid, name, version = split(entry, '='; limit = 3)
    Base.PkgId(Base.UUID(uuid), String(name)) => (version == "-" ? nothing : VersionNumber(version))
end

report(line) = (println(stdout, line); flush(stdout))

# Precompile failures surface again, with context, when the package is loaded.
function precompile_packages(packages)
    names = [id.name for (id, _) in packages if !isfile(joinpath(Sys.STDLIB, id.name, "Project.toml"))]
    isempty(names) && return
    report("precompiling start")
    try
        Base.invokelatest(Base.require(PKG_ID).precompile, names)
    catch err
        is_interrupt(err) && rethrow()
        @error "Precompiling $(join(names, ", ")) failed; indexing anyway" exception = (err, catch_backtrace())
    end
    report("precompiling done")
end

# Names are recorded at the requested (manifest) version, the one the catalog
# will be asked about, rather than `pkgversion`.
function index_package(path, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    report("indexing $(id.uuid)")
    record = try
        names = Base.invokelatest(extract_names, Base.require(id), id)
        version === nothing ? names : PkgNames(id, [version], names.exported, names.public, names.reexported)
    catch err
        is_interrupt(err) && rethrow()
        @error "Failed to load $(id.name) for indexing" exception = (err, catch_backtrace())
        PkgFailure(id, version, first(sprint(showerror, err), MAX_MESSAGE_CHARS))
    end
    write_catalog_changes!(path, CatalogRecord[record])
end

# Loading wraps an interrupt in `LoadError`/`InitError`.
is_interrupt(err) =
    err isa InterruptException || ((err isa LoadError || err isa InitError) && is_interrupt(err.error))

# ── Entry point ──

# Julia 1.12.7 segfaults on SIGINT with this set (exit 0, signal 11), so an
# interrupt there is recorded as a crash of the package in progress.
Base.exit_on_sigint(false)
try
    main(ARGS)
catch err
    is_interrupt(err) || rethrow()
    exit(INTERRUPTED_EXIT_CODE)
end
