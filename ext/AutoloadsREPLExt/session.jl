# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The session: one worker task owns everything derived from the environments
# and the catalog. The REPL transform, package callbacks and environment
# notifications only post events; the worker drains them in batches and swaps
# an immutable `Session` at most once per batch. Load bookkeeping (`LOAD`) and
# the transform's change stamp live with the REPL backend task.

const MISSING_FILE_STAMP = (0.0, Int64(0), UInt64(0))
const STOP_WAIT_S = 2.0

"""
    Session(catalog, registry, config, member, member_deps)

What the worker last derived: the catalog, the registry of names that may
autoload under `config`, the autoloads `member` directory and the names of
its direct dependencies.
"""
struct Session
    catalog::Catalog
    registry::Registry
    config::Config
    member::String
    member_deps::Set{String}
end

"Holds the current [`Session`](@ref); written only by the worker."
mutable struct SessionRef
    @atomic session::Union{Session, Nothing}
end

"Re-derive the session from the environments and the catalog."
struct Refresh end

"Package `id` was loaded into this session; record its names."
struct Observed
    id::Base.PkgId
end

"Put `nothing` into `done` once every event posted before this one is handled."
struct Flush
    done::Channel{Nothing}
end

const Event = Union{Refresh, Observed, Flush}

# (mtime, size, inode) of each watched file.
const FileStamp = Tuple{Float64, Int64, UInt64}
# The catalog is apart: its changes call for a refresh, but not for retrying failed loads.
const EnvStamp = @NamedTuple{active::Union{String, Nothing}, environment::NTuple{8, FileStamp}, catalog::FileStamp}

"""
    Runtime(events, member, catalog_path)

One session's fixed parts: the worker's event channel and start event, the
autoloads `member` directory and the catalog file. `stamp` (the environment
files as last seen by the transform) and the failure flags belong to the REPL
backend task; once `is_stopping` is set (at exit), the worker handles no more
batches.
"""
mutable struct Runtime
    const events::Channel{Event}
    const member::String
    const catalog_path::String
    const worker_start::Base.Event
    stamp::Union{EnvStamp, Nothing}
    has_reported_transform_failure::Bool
    has_reported_prepare_failure::Bool
    @atomic is_stopping::Bool
end

Runtime(events::Channel{Event}, member::AbstractString, catalog_path::AbstractString) =
    Runtime(events, String(member), String(catalog_path), Base.Event(), nothing, false, false, false)

"""
    WorkerStart(runtime, repl = nothing)

Starts `runtime`'s deferred worker: from a `Timer`, once `repl` (if any) is
at its first prompt; from `atreplinit`, by polling for that prompt, which
comes after every other `atreplinit` hook has run.
"""
struct WorkerStart <: Function
    runtime::Runtime
    repl::Union{REPL.LineEditREPL, Nothing}
end

WorkerStart(runtime::Runtime) = WorkerStart(runtime, nothing)

function (start::WorkerStart)(timer::Timer)
    (; repl) = start
    repl === nothing || !hasfield(REPL.LineEditREPL, :mistate) || repl.mistate !== nothing || return
    close(timer)
    notify(start.runtime.worker_start)
end

(start::WorkerStart)(repl::REPL.AbstractREPL) =
    Timer(WorkerStart(start.runtime, repl isa REPL.LineEditREPL ? repl : nothing), WORKER_START_POLL_S;
          interval = WORKER_START_POLL_S)

"""
    Worker(runtime, indexer)

The worker's own state: the built-in records and stdlib ids (computed once),
the configuration, observation and refresh errors logged since each last
succeeded (see [`is_unreported!`](@ref)), the unknown `packages.<Name>`
settings last warned about, and the environment upkeep done (see
[`maintain_environment!`](@ref)).
"""
struct Worker
    runtime::Runtime
    indexer::Indexer
    builtins::Vector{PkgNames}
    stdlibs::Vector{Base.PkgId}
    reported_config_errors::Set{String}
    reported_observation_errors::Set{String}
    reported_refresh_errors::Set{String}
    reported_unknown_packages::Set{String}
    has_tried_setup::Base.RefValue{Bool}
    deferred_stamp::Base.RefValue{FileStamp}
end

Worker(runtime::Runtime, indexer::Indexer) =
    Worker(runtime, indexer, builtin_records(), stdlib_ids(), Set{String}(), Set{String}(), Set{String}(),
           Set{String}(), Ref(false), Ref(MISSING_FILE_STAMP))

"`Base.package_callbacks` entry: only enqueues an [`Observed`](@ref) event."
struct ObserveLoad
    events::Channel{Event}
end

(observe::ObserveLoad)(id::Base.PkgId) = (put!(observe.events, Observed(id)); nothing)

const SESSION = SessionRef(nothing)
const LOAD = LoadState()
const RUNTIME = Ref{Union{Runtime, Nothing}}(nothing)

"""
    start_session!(; member = member_dir(), catalog = catalog_path(), is_deferred = false) -> Runtime

Start this process's session: register load observation and environment
change notification, start the worker (stopped by [`stop_worker!`](@ref) at
exit) and request the first refresh. With `is_deferred`, the worker waits
for `notify(runtime.worker_start)`. Inputs pass through
[`repl_transform`](@ref) unchanged until the first session is derived. Once
started, later calls return the running session's runtime unchanged
(`__init__` starts it in interactive sessions).
"""
function start_session!(; member::AbstractString = member_dir(), catalog::AbstractString = catalog_path(),
                        is_deferred::Bool = false)
    RUNTIME[] === nothing || return RUNTIME[]
    runtime = Runtime(Channel{Event}(Inf), member, catalog)
    events = runtime.events
    RUNTIME[] = runtime
    push!(Base.package_callbacks, ObserveLoad(events))
    Autoloads.ENV_CHANGED[] = () -> put!(events, Refresh())
    worker_start = runtime.worker_start
    # `invokelatest` keeps the worker's code out of the cache, where compiling it costs no stall.
    @static if IS_COMPILATION_SERIALISED
        errormonitor(Threads.@spawn (wait(worker_start); run_worker(Worker(runtime, Indexer()))))
    else
        errormonitor(Threads.@spawn (wait(worker_start); Base.invokelatest(run_worker, Worker(runtime, Indexer()))))
    end
    atexit(() -> stop_worker!(runtime))
    put!(events, Refresh())
    is_deferred || notify(worker_start)
    runtime
end

"""
    stop_worker!(runtime)

Stop the worker of `runtime` handling batches, and wait (up to
$(STOP_WAIT_S) s) for the batch in progress to finish: exiting while the
worker compiles or writes can crash the process.
"""
function stop_worker!(runtime::Runtime)
    @atomic runtime.is_stopping = true
    notify(runtime.worker_start)
    done = Channel{Nothing}(1)
    put!(runtime.events, Flush(done))
    timedwait(() -> isready(done), STOP_WAIT_S; pollint = 0.01)
    nothing
end

"""
    repl_transform(ex) -> Any

The REPL AST transform. When the session's environment files or catalog
changed since the last input, requests a refresh and, unless only the
catalog changed, forgets failed loads (see [`forget_failures!`](@ref)). With
a session and `Main` active, a statement that imports a member-only package
is evaluated through [`eval_with_member`](@ref) and any other statement that
could need an autoload is preceded by a [`prepare_statement`](@ref) call;
other input is returned as is. Never throws, except `InterruptException`: an internal error
is logged once per session and `ex` returned.
"""
function repl_transform(ex)
    runtime = RUNTIME[]
    (runtime === nothing || Base.active_module() !== Main) && return ex
    try
        transform_input(runtime, ex)
    catch err
        err isa InterruptException && rethrow()
        report_once!(runtime, :has_reported_transform_failure, "Autoloads transform failed", err, catch_backtrace())
        ex
    end
end

"""
    prepare_statement(stmt)

Load what `stmt` needs into `Main` just before it is evaluated: the owners
of the undefined macros it invokes, then those of the undefined `Main`
globals it reads once lowered. Failures are reported by [`load!`](@ref) and
never thrown, except an interrupt.
"""
function prepare_statement(stmt)
    session = @atomic SESSION.session
    session === nothing && return nothing
    try
        load_pending!(session, statement_macros(stmt))
        # Lowering runs in the newest world too, so macros just loaded expand.
        Base.invokelatest(() -> load_pending!(session, undefined_globals(stmt, Main)))
    catch err
        is_interrupt(err) && rethrow()
        report_once!(RUNTIME[]::Runtime, :has_reported_prepare_failure, "Autoloads failed to prepare a statement",
                     err, catch_backtrace())
    end
    nothing
end

# ── Worker ──

function run_worker(worker::Worker)
    (; events) = runtime = worker.runtime
    for event in events
        batch = next_batch!(events, event)
        try
            (@atomic runtime.is_stopping) || handle_batch!(worker, batch)
        catch err
            @error "Autoloads failed to update its session" exception = (err, catch_backtrace())
        finally
            foreach(flush -> put!(flush.done, nothing), (e for e in batch if e isa Flush))
        end
    end
end

"`first` (taken already, else taken now) and every event pending behind it."
function next_batch!(events::Channel{Event}, first::Event = take!(events))
    batch = Event[first]
    while isready(events)
        push!(batch, take!(events))
    end
    batch
end

"""
Record the observed packages, then refresh once if the catalog or the
environment changed. A failed observation or refresh is logged once per
distinct error until it succeeds again; a failed observation never prevents
the refresh.
"""
function handle_batch!(worker::Worker, batch::Vector{Event})
    observed = unique(event.id for event in batch if event isa Observed)
    has_written = try
        written = observe!(worker, observed)
        isempty(observed) || empty!(worker.reported_observation_errors)
        written
    catch err
        is_unreported!(worker.reported_observation_errors, err) &&
            @error "Autoloads failed to record loaded packages in its catalog" packages = observed exception =
                (err, catch_backtrace())
        false
    end
    (has_written || any(event -> event isa Refresh, batch)) || return
    try
        refresh!(worker)
        empty!(worker.reported_refresh_errors)
    catch err
        is_unreported!(worker.reported_refresh_errors, err) &&
            @error "Autoloads failed to update its session" exception = (err, catch_backtrace())
    end
    nothing
end

"Write the namespaces of loaded packages `ids` to the catalog; whether it changed."
function observe!(worker::Worker, ids)
    records = CatalogRecord[]
    for id in ids
        id.uuid === nothing && continue
        record = Base.invokelatest(extract_names, Base.root_module(id), id)
        # Extensions offer no names beyond their own.
        is_own_name_only = isempty(record.public) && isempty(record.reexported) && length(record.exported) == 1
        is_own_name_only || push!(records, record)
    end
    !isempty(records) && write_catalog_changes!(worker.runtime.catalog_path, records)
end

"""
Derive and swap the session, then index what it lacks. No session when the
settings are invalid, or when there is neither a member nor a selected
project dependency.
"""
function refresh!(worker::Worker)
    maintain_environment!(worker)
    session, plan = derive_session(worker)
    @atomic SESSION.session = session
    session === nothing && return
    @debug "Autoloads session refreshed" names = length(session.registry.owners) catalog = length(session.catalog.records)
    start_next_index_run!(worker, session.config.policy, session.catalog, plan)
end

function derive_session(worker::Worker)
    cfg = read_config!(worker)
    cfg === nothing && return nothing, nothing
    member = worker.runtime.member
    member_project = joinpath(member, "Project.toml")
    active = Base.active_project()
    member_env, project_env = environment(member_project), environment(active)
    selected = [id for id in project_env.deps if cfg.project === nothing || id.name in cfg.project]
    has_member = isfile(member_project)
    has_member || !isempty(selected) || return nothing, nothing
    autoload = autoload_set(member_env.deps, member_env.graph, project_env.deps, project_env.graph,
                            worker.stdlibs, [record.id for record in worker.builtins], cfg)
    warn_unknown_packages!(worker.reported_unknown_packages, cfg, autoload)
    catalog = build_catalog(append!(convert(Vector{CatalogRecord}, worker.builtins),
                                    read_healed_catalog(worker.runtime.catalog_path)))
    session = Session(catalog, build_registry(catalog, autoload, cfg), cfg, member,
                      Set(id.name for id in member_env.deps))
    # Stdlibs are always indexed, for hints. Without a member, a session implies an active project.
    plan = [(has_member ? member : dirname(active)) =>
                wanted_versions(member_env.graph, [member_env.deps; worker.stdlibs])]
    active === nothing || push!(plan, dirname(active) => wanted_versions(project_env.graph, selected))
    session, plan
end

"""
Keep this version's autoloads environment set up without user action: the
first time a session finds none, create it from the newest older Julia
version's (see `Autoloads.adopt_previous!`), and apply the changes other
versions deferred to it whenever they change (`Autoloads.apply_deferred!`).
Pkg's output is shown only when it fails; a failure is not retried until the
deferred changes change, or the next session.
"""
function maintain_environment!(worker::Worker)
    global_dir = dirname(worker.runtime.member)
    function quietly(f, purpose)
        output = IOBuffer()
        try
            f(output)
        catch err
            err isa InterruptException && rethrow()
            @error "Autoloads could not $purpose" output = String(take!(output)) exception = (err, catch_backtrace())
            nothing
        end
    end
    if !worker.has_tried_setup[] && !isfile(joinpath(worker.runtime.member, "Project.toml"))
        worker.has_tried_setup[] = true
        previous = quietly(output -> Autoloads.adopt_previous!(global_dir; output),
                           "set up the autoloads environment from an older Julia version's")
        previous === nothing ||
            @info "Autoloads set up its environment for Julia $(VERSION.major).$(VERSION.minor), carrying over \
                   $(join(previous.names, ", ")) and the settings from Julia $(VERSION.major).$(previous.minor)"
    end
    stamp = file_stamp(joinpath(state_dir(), Autoloads.DEFERRED_FILE))
    stamp == worker.deferred_stamp[] && return
    worker.deferred_stamp[] = stamp
    stamp == MISSING_FILE_STAMP ||
        quietly(output -> Autoloads.apply_deferred!(global_dir; output), "apply the changes made from other Julia versions")
end

"""
Warn about `packages.<Name>` settings in `cfg` naming no package in
`autoload` (as from `autoload_set`). `reported` holds the names last warned
about, so each warns once, and again if it becomes known and then unknown.
"""
function warn_unknown_packages!(reported::Set{String}, cfg::Config, autoload::AbstractDict)
    unknown = setdiff(keys(cfg.packages), (id.name for id in keys(autoload)))
    newly_unknown = sort!(collect(setdiff(unknown, reported)))
    isempty(newly_unknown) ||
        @warn "Autoloads has settings for packages it does not autoload here: $(join(newly_unknown, ", ")). \
               Check the `packages` names in [preferences.Autoloads], or add them with `pkg> autoloads add`."
    empty!(reported)
    union!(reported, unknown)
end

"""
`load_config()`, or `nothing` after logging a `ConfigError` once per distinct
error; valid settings forget past errors, so a reintroduced one logs again.
"""
function read_config!(worker::Worker)
    try
        cfg = load_config()
        empty!(worker.reported_config_errors)
        cfg
    catch err
        err isa ConfigError || rethrow()
        is_unreported!(worker.reported_config_errors, err) &&
            @error "Autoloads is off until its settings are fixed" exception = err
        nothing
    end
end

"Start indexing the first environment in `plan` with packages `catalog` lacks."
function start_next_index_run!(worker::Worker, policy::PrecompilePolicy, catalog::Catalog, plan)
    for (project, wanted) in plan
        missing_ids = to_index(catalog, wanted)
        isempty(missing_ids) && continue
        pairs = Pair{Base.PkgId, Union{VersionNumber, Nothing}}[id => wanted[id] for id in missing_ids]
        events = worker.runtime.events
        start_indexing!(worker.indexer, policy, project, worker.runtime.catalog_path, pairs,
                        changed -> changed && put!(events, Refresh()))
        return
    end
end

# ── Transform ──

function transform_input(runtime::Runtime, ex)
    stamp, previous = env_stamp(runtime), runtime.stamp
    # `===`, as later loads invalidate a generic `!=` on the stamps.
    is_same_environment = previous !== nothing && stamp.active == previous.active &&
        stamp.environment === previous.environment
    if !is_same_environment || stamp.catalog !== previous.catalog
        runtime.stamp = stamp
        is_same_environment || forget_failures!(LOAD)
        put!(runtime.events, Refresh())
    end
    session = @atomic SESSION.session
    session === nothing ? ex : transform_statements(session, ex)
end

"""
Route each statement of `ex` per [`repl_transform`](@ref). Pure, but for the
`identify_package` lookups of imported member dependencies.
"""
function transform_statements(session::Session, ex)
    member_only(root::Symbol) =
        String(root) in session.member_deps && Base.identify_package(String(root)) === nothing
    map_statements(ex) do stmt
        is_candidate_statement(session.registry, stmt, member_only) || return stmt
        has_member_only_using(stmt, member_only) &&
            return Expr(:call, GlobalRef(@__MODULE__, :eval_with_member), QuoteNode(stmt), session.member)
        Expr(:toplevel, Expr(:call, GlobalRef(@__MODULE__, :prepare_statement), QuoteNode(stmt)), stmt)
    end
end

"""
The active project and the stamps of the files whose change calls for a
refresh: the `environment` (the root and active projects with their
manifests and local preferences) and the `catalog`.
"""
function env_stamp(runtime::Runtime)
    active = Base.active_project()
    root_project = joinpath(dirname(runtime.member), "Project.toml")
    files = (root_project, manifest_of(root_project), preferences_files(root_project)...,
             active, manifest_of(active), preferences_files(active)...)
    (; active, environment = map(file_stamp, files), catalog = file_stamp(runtime.catalog_path))
end

# ── Helpers ──

function load_pending!(session::Session, names)
    isbound(name) = isdefined(Main, name)
    for request in pending_loads(session.registry, session.config, names, isbound, LOAD.attempted)
        load!(LOAD, request, session.member; announce = session.config.log)
    end
end

"""
    is_unreported!(reported, err) -> Bool

Whether `err` is to be logged: its `showerror` text is not among the
`reported` texts, which it then joins. Emptying `reported` once the failing
operation succeeds lets a recurring error be logged once until it clears.
"""
function is_unreported!(reported::Set{String}, err)
    message = sprint(showerror, err)
    message in reported && return false
    push!(reported, message)
    true
end

"Log `message` with `err` unless the `flag` field of `runtime` says it was already logged."
function report_once!(runtime::Runtime, flag::Symbol, message, err, backtrace)
    getfield(runtime, flag) && return
    setfield!(runtime, flag, true)
    @error message exception = (err, backtrace)
end

wanted_versions(graph::ManifestGraph, ids) =
    Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => get(graph.versions, id.uuid, nothing) for id in ids)

manifest_of(project_file::Union{String, Nothing}) =
    project_file === nothing || !isfile(project_file) ? nothing : Base.project_file_manifest_path(project_file)

# The files Base reads preferences from beside `project_file`, besides itself.
preferences_files(project_file::Union{String, Nothing}) = project_file === nothing ? (nothing, nothing) :
    (joinpath(dirname(project_file), "LocalPreferences.toml"), joinpath(dirname(project_file), "JuliaLocalPreferences.toml"))

function file_stamp(path::Union{String, Nothing})
    path === nothing && return MISSING_FILE_STAMP
    st = stat(path)
    ispath(st) ? (Float64(st.mtime), Int64(st.size), UInt64(st.inode)) : MISSING_FILE_STAMP
end
