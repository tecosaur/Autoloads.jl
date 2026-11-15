# Indexer supervision: one `nice`d, detached subprocess (`src/scripts/index.jl`)
# loads packages and writes their names to the catalog; a supervisor task
# logs its output, enforces a per-package timeout, and records a failure for
# the package in progress when the subprocess dies of anything but an
# interruption. This session never loads packages to index them.

const DEFAULT_TIMEOUT_S = 300
const LOG_MAX_BYTES = 1 << 20
# Ways of being stopped from outside; any other signal is the package's doing.
const INTERRUPT_SIGNALS = (Base.SIGINT, Base.SIGTERM, Base.SIGHUP)
const POLICY_FLAGS = Dict(Lazy => `--compiled-modules=existing --compile=min -O0`, Background => ``)
const INDEXER_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)

"""
    Indexer(; timeout_s = $DEFAULT_TIMEOUT_S)

Runs at most one indexer subprocess at a time; see [`start_indexing!`](@ref).
A package that takes longer than `timeout_s` seconds to load (precompilation
excluded) is recorded as failed. Use from a single task.
"""
mutable struct Indexer
    supervisor::Union{Task, Nothing}
    const timeout_s::Int
end

Indexer(; timeout_s::Integer = DEFAULT_TIMEOUT_S) = Indexer(nothing, timeout_s)

"""
    start_indexing!(ix, policy, project, path, wanted, on_exit) -> Bool

Index the packages of `wanted` (`id => manifest version` pairs, `nothing` if
unknown), in order, into the catalog at `path`, in a subprocess using
environment `project`. Returns `false` without starting anything if `ix`
already has a run in progress or `wanted` is empty.

`policy` is the [`PrecompilePolicy`](@ref): `Background` first precompiles
the non-stdlib packages with this session's flags; `Lazy` writes no caches.
The subprocess's output is appended to `path * ".log"`. If another session's
indexer holds the catalog's `.indexing` lock, the subprocess exits at once.

Once the subprocess exits, a failure is recorded for the package it was
loading if it timed out, crashed or exited abnormally (but not when
interrupted by SIGINT, SIGTERM or SIGHUP); packages after it stay unrecorded
so they are retried. A subprocess that fails to start is logged. Either way,
once the run is over `on_exit(changed::Bool)` is called on a spawned task,
`changed` being whether the catalog file differs from before the run; `ix`
is free by then, so `on_exit` may start the next run.
"""
function start_indexing!(ix::Indexer, policy::PrecompilePolicy, project::AbstractString, path::AbstractString,
                         wanted::Vector{Pair{Base.PkgId, Union{VersionNumber, Nothing}}}, on_exit::Function)
    ix.supervisor === nothing || istaskdone(ix.supervisor) || return false
    isempty(wanted) && return false
    stamp = catalog_stamp(path)
    mkpath(dirname(path))
    script = joinpath(pkgdir(Autoloads), "src", "scripts", "index.jl")
    entries = ["$(id.uuid)=$(id.name)=$(something(version, "-"))" for (id, version) in wanted]
    cmd = julia_command(`$(POLICY_FLAGS[policy]) $script $(lowercase(string(policy))) $path $entries`;
                        project, env = INDEXER_ENV, nice = true, detach = true)
    supervisor = Threads.@spawn launch_and_supervise(cmd, project, path, wanted, ix.timeout_s)
    ix.supervisor = errormonitor(supervisor)
    errormonitor(Threads.@spawn begin
        wait(supervisor; throw = false)
        on_exit(catalog_stamp(path) != stamp)
    end)
    true
end

# ── Helpers ──

"""
    exit_failure(in_progress, exitcode, termsignal, timed_out, timeout_s) -> Union{PkgFailure, Nothing}

The failure to record for `in_progress` (the `id => version` last announced,
or `nothing`) given how the indexer exited.
"""
function exit_failure(in_progress, exitcode::Integer, termsignal::Integer, timed_out::Bool, timeout_s::Integer)
    in_progress === nothing && return nothing
    exitcode == 0 && termsignal == 0 && return nothing
    id, version = in_progress
    timed_out && termsignal == Base.SIGKILL &&
        return PkgFailure(id, version, "indexer timed out after $timeout_s s while indexing")
    termsignal in INTERRUPT_SIGNALS && return nothing
    termsignal == 0 && exitcode == INTERRUPTED_EXIT_CODE && return nothing
    termsignal != 0 && return PkgFailure(id, version, "indexer killed by signal $termsignal while indexing")
    PkgFailure(id, version, "indexer exited with code $exitcode while indexing")
end

function catalog_stamp(path)
    st = stat(path)
    ispath(st) ? (st.mtime, st.size) : nothing
end

function launch_and_supervise(cmd::Base.AbstractCmd, project, path, wanted, timeout_s)
    output = Pipe()
    process = try
        run(pipeline(cmd; stdout = output, stderr = output); wait = false)
    catch err
        @error "Could not start the indexer for $project; its packages are retried on the next refresh" path exception =
            (err, catch_backtrace())
        return
    end
    close(output.in)
    pid = getpid(process)
    @debug "Indexer started" pid project count = length(wanted)
    supervise(process, pid, output, path, wanted, timeout_s)
end

function supervise(process::Base.Process, pid::Integer, output::Pipe, path, wanted, timeout_s)
    by_uuid = Dict(id.uuid => (id => version) for (id, version) in wanted)
    timed_out = Threads.Atomic{Bool}(false)
    timer = Ref{Union{Timer, Nothing}}(nothing)
    disarm!() = (timer[] === nothing || close(timer[]); timer[] = nothing)
    function arm!()
        disarm!()
        timer[] = Timer(timeout_s) do _
            process_running(process) || return
            timed_out[] = true
            kill(process, Base.SIGKILL)
        end
    end
    in_progress = nothing
    try
        # Armed only by `indexing` lines, so startup and precompilation never count.
        log_path = path * ".log"
        open(log_path, filesize(log_path) > LOG_MAX_BYTES ? "w" : "a") do log
            for line in eachline(output)
                println(log, line)
                flush(log)
                startswith(line, "indexing ") || continue
                uuid = tryparse(Base.UUID, chopprefix(line, "indexing "))
                haskey(by_uuid, uuid) || continue
                in_progress = by_uuid[uuid]
                arm!()
            end
            disarm!()
            wait(process)
            close(output)
            println(log, "indexer $pid exited with code $(process.exitcode), signal $(process.termsignal)")
        end
        failure = exit_failure(in_progress, process.exitcode, process.termsignal, timed_out[], timeout_s)
        if failure !== nothing
            @debug "Recording indexer failure" failure.id failure.message
            write_catalog_changes!(path, CatalogRecord[failure])
        end
        success(process) || release_indexing_lock(path * ".indexing", pid)
    finally
        disarm!()
        # Never leave the child running unsupervised after a supervisor error.
        process_running(process) && kill(process, Base.SIGKILL)
    end
end

# A killed indexer leaves its lock behind, blocking the next run until it goes stale.
# Best effort: the lock goes stale on its own anyway.
function release_indexing_lock(lock_path, pid)
    try
        isfile(lock_path) || return
        fields = split(read(lock_path, String))
        !isempty(fields) && tryparse(Int, fields[1]) == pid && rm(lock_path; force = true)
    catch err
        @debug "Could not release the indexing lock" lock_path pid exception = err
    end
end
