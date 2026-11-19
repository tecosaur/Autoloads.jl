# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Supervises the indexer subprocess: its log, a per-package timeout, and a
# failure recorded for the package a crash interrupts.

const DEFAULT_TIMEOUT_S = 300
const LOG_MAX_BYTES = 1 << 20
# Ways of being stopped from outside; any other signal is the package's doing.
const INTERRUPT_SIGNALS = (Base.SIGINT, Base.SIGTERM, Base.SIGHUP)
const POLICY_FLAGS = Dict(Lazy => `--compiled-modules=existing --compile=min -O0`, Background => ``)
const INDEXER_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)

"""
    Indexer(; timeout_s = $DEFAULT_TIMEOUT_S)

Runs at most one indexer subprocess at a time, failing a package that takes
over `timeout_s` to load. Use from one task.
"""
mutable struct Indexer
    supervisor::Union{Task, Nothing}
    const timeout_s::Int
    const reported_errors::Set{String}
end

Indexer(; timeout_s::Integer = DEFAULT_TIMEOUT_S) = Indexer(nothing, timeout_s, Set{String}())

"""
    start_indexing!(ix, policy, project, path, wanted, on_exit) -> Bool

Index `wanted` (`id => version` pairs), in order, into the catalog at `path` in
a subprocess using `project`, unless a run is in progress (then `false`). The
package being loaded when the subprocess crashes or times out is recorded as
failed, but not when it is interrupted. Once the run is over, `on_exit(changed)`
is called on a new task, `changed` being whether the catalog was written.
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
    supervisor = Threads.@spawn launch_and_supervise(cmd, project, path, wanted, ix.timeout_s, ix.reported_errors)
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

The failure to record for `in_progress`, the package being indexed (or
`nothing`), given how the indexer exited.
"""
function exit_failure(in_progress, exitcode::Integer, termsignal::Integer, timed_out::Bool, timeout_s::Integer)
    in_progress === nothing && return nothing
    exitcode == 0 && termsignal == 0 && return nothing
    id, version = in_progress
    at = Sighting[(; version, julia = JULIA_MINOR)]
    timed_out && termsignal == Base.SIGKILL &&
        return PkgFailure(id, at, "indexer timed out after $timeout_s s while indexing")
    termsignal in INTERRUPT_SIGNALS && return nothing
    termsignal == 0 && exitcode == INTERRUPTED_EXIT_CODE && return nothing
    termsignal != 0 && return PkgFailure(id, at, "indexer killed by signal $termsignal while indexing")
    PkgFailure(id, at, "indexer exited with code $exitcode while indexing")
end

function catalog_stamp(path)
    st = stat(path)
    if ispath(st); (st.mtime, st.size) end
end

function launch_and_supervise(cmd::Base.AbstractCmd, project, path, wanted, timeout_s, reported::Set{String})
    output = Pipe()
    process = try
        run(pipeline(cmd; stdin = devnull, stdout = output, stderr = output); wait = false)
    catch err
        is_unreported!(reported, err) &&
            @error "Could not start the indexer for $project; its packages are retried on the next refresh" path exception =
                (err, catch_backtrace())
        return
    end
    close(output.in)
    pid = getpid(process)
    @debug "Indexer started" pid project count = length(wanted)
    try
        supervise(process, pid, output, path, wanted, timeout_s)
        empty!(reported)
    catch err
        is_unreported!(reported, err) &&
            @error "Supervising the indexer for $project failed; its packages are retried on the next refresh" pid path exception =
                (err, catch_backtrace())
    end
end

function supervise(process::Base.Process, pid::Integer, output::Pipe, path, wanted, timeout_s)
    by_uuid = Dict{Base.UUID, eltype(wanted)}(first(entry).uuid => entry for entry in wanted)
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
        # Armed from `indexing` to `indexed`, so startup, precompilation and exit never count.
        log_path = path * ".log"
        open(log_path, if filesize(log_path) > LOG_MAX_BYTES "w" else "a" end) do log
            for line in eachline(output)
                println(log, line)
                flush(log)
                if startswith(line, "indexing ")
                    uuid = tryparse(Base.UUID, chopprefix(line, "indexing "))
                    haskey(by_uuid, uuid) || continue
                    in_progress = by_uuid[uuid]
                    arm!()
                elseif in_progress !== nothing && line == "indexed $(first(in_progress).uuid)"
                    in_progress = nothing
                    disarm!()
                end
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
        success(process) || release_indexing_lock(path * INDEXING_LOCK_SUFFIX, pid)
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
