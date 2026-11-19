# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# One worker task owns everything derived from the environments and catalog; the
# transform, load callbacks and change notifications only post events to it.

const MISSING_FILE_STAMP = (0.0, Int64(0), UInt64(0))
const STOP_WAIT_S = 2.0
const FIRST_REFRESH_WAIT_S = 2.0

"""
    Session(catalog, registry, config, member, member_deps)

What the worker last derived from the environments and the catalog.
"""
struct Session
    catalog::Catalog
    registry::Registry
    config::Config
    member::String
    member_deps::Set{String}
end

"""
    SessionRef(session)

Holds the current `Session`; written only by the worker.
"""
mutable struct SessionRef
    @atomic session::Union{Session, Nothing}
end

struct Refresh end

struct Observed
    id::Base.PkgId
end

"""
    Flush(done)

Put `nothing` into `done` once every event posted before this one is handled.
"""
struct Flush
    done::Channel{Nothing}
end

const Event = Union{Refresh, Observed, Flush}

# (mtime, size, inode) of each watched file.
const FileStamp = Tuple{Float64, Int64, UInt64}
# The catalog is apart: its changes call for a refresh, but not for retrying failed loads.
const EnvStamp = @NamedTuple{active::Union{String, Nothing}, environment::NTuple{9, FileStamp}, catalog::FileStamp}

"""
    Runtime(events, member, catalog_path)

One session's fixed parts. `stamp` belongs to the REPL backend task; once
`is_stopping` is set, at exit, the worker handles no more batches.
"""
mutable struct Runtime
    const events::Channel{Event}
    const member::String
    const catalog_path::String
    stamp::Union{EnvStamp, Nothing}
    @atomic is_stopping::Bool
    @atomic has_refreshed::Bool
end

Runtime(events::Channel{Event}, member::AbstractString, catalog_path::AbstractString) =
    Runtime(events, String(member), String(catalog_path), nothing, false, false)

"""
    Worker(runtime, indexer)

The worker's own state, including the errors it last reported, so that each is
logged once until it clears.
"""
mutable struct Worker
    const runtime::Runtime
    const indexer::Indexer
    const builtins::Vector{PkgNames}
    const stdlibs::Vector{Base.PkgId}
    const reported_config_errors::Set{String}
    const reported_observation_errors::Set{String}
    const reported_refresh_errors::Set{String}
    const reported_unknown_packages::Set{String}
    has_tried_setup::Bool
    deferred_stamp::FileStamp
end

Worker(runtime::Runtime, indexer::Indexer) =
    Worker(runtime, indexer, builtin_records(), stdlib_ids(), Set{String}(), Set{String}(), Set{String}(),
           Set{String}(), false, MISSING_FILE_STAMP)

struct ObserveLoad
    events::Channel{Event}
end

(observe::ObserveLoad)(id::Base.PkgId) = (put!(observe.events, Observed(id)); nothing)

const SESSION = SessionRef(nothing)
const LOAD = LoadState()
const RUNTIME = Ref{Union{Runtime, Nothing}}(nothing)

"""
    start_session!(; member = member_dir(), catalog = catalog_path()) -> Runtime

Start this process's session, once: observe loads and environment changes,
start the worker, and request the first refresh.
"""
function start_session!(; member::AbstractString = member_dir(), catalog::AbstractString = catalog_path())
    RUNTIME[] === nothing || return RUNTIME[]
    runtime = Runtime(Channel{Event}(Inf), member, catalog)
    events = runtime.events
    RUNTIME[] = runtime
    push!(Base.package_callbacks, ObserveLoad(events))
    Autoloads.ENV_CHANGED[] = () -> put!(events, Refresh())
    errormonitor(Threads.@spawn run_worker(Worker(runtime, Indexer())))
    atexit(() -> stop_worker!(runtime))
    put!(events, Refresh())
    runtime
end

"""
    stop_worker!(runtime)

Stop the worker and wait (up to $(STOP_WAIT_S) s) for its batch in progress:
exiting while it compiles or writes can crash the process.
"""
function stop_worker!(runtime::Runtime)
    @atomic runtime.is_stopping = true
    done = Channel{Nothing}(1)
    put!(runtime.events, Flush(done))
    timedwait(() -> isready(done), STOP_WAIT_S; pollint = 0.01)
    nothing
end

"""
    repl_transform(ex) -> Any

The REPL AST transform. Requests a refresh when the environment or catalog
changed, and precedes each statement that may need an autoload with
`prepare_statement` (or runs it through `eval_with_member`). Throws only on
interrupt.
"""
function repl_transform(ex)
    runtime = RUNTIME[]
    (runtime === nothing || Base.active_module() !== Main) && return ex
    try
        transform_input(runtime, ex)
    catch err
        err isa InterruptException && rethrow()
        @error "Autoloads transform failed" exception = (err, catch_backtrace()) maxlog = 1
        ex
    end
end

"""
    prepare_statement(stmt)

Load what `stmt` needs into `Main` before it runs: the owners of the undefined
macros it invokes, then of the globals it reads once lowered or, in help mode,
asks about.
"""
function prepare_statement(stmt)
    session = @atomic SESSION.session
    session === nothing && return nothing
    try
        load_pending!(session, statement_macros(stmt))
        # Lowering runs in the newest world, so macros just loaded expand.
        load_pending!(session, @something(help_query_names(stmt),
                                          Base.invokelatest(undefined_globals, stmt, Main)::Vector{Symbol}))
    catch err
        is_interrupt(err) && rethrow()
        @error "Autoloads failed to prepare a statement" exception = (err, catch_backtrace()) maxlog = 1
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

function next_batch!(events::Channel{Event}, first::Event = take!(events))
    batch = Event[first]
    while isready(events)
        push!(batch, take!(events))
    end
    batch
end

"""
    handle_batch!(worker, batch)

Record the observed packages, then refresh once if anything changed. Each
failure is logged once until it clears.
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
    finally
        @atomic worker.runtime.has_refreshed = true
    end
    nothing
end

function observe!(worker::Worker, ids)
    records = CatalogRecord[]
    for id in ids
        id.uuid === nothing && continue
        record = Base.invokelatest(extract_names, Base.root_module(id), id)
        # Extensions offer no names beyond their own.
        is_own_name_only = isempty(record.public) && isempty(record.reexported) && length(record.exported) == 1
        is_own_name_only || push!(records, record)
    end
    isempty(records) && return false
    try
        write_catalog_changes!(worker.runtime.catalog_path, records)
    catch err
        err isa CatalogTooNew || rethrow()
        false  # `derive_session` warns of it
    end
end

"""
    refresh!(worker)

Derive and swap the session, then index what it lacks.
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
    records = try
        read_healed_catalog(worker.runtime.catalog_path)
    catch err
        err isa CatalogTooNew || rethrow()
        @warn "Autoloads is off" exception = err maxlog = 1
        return nothing, nothing
    end
    catalog = build_catalog(append!(convert(Vector{CatalogRecord}, worker.builtins), records))
    session = Session(catalog, build_registry(catalog, autoload, cfg), cfg, member,
                      Set(id.name for id in member_env.deps))
    # Stdlibs are always indexed, for hints. Without a member, a session implies an active project.
    plan = [if has_member member else dirname(active) end =>
                wanted_versions(member_env.graph, [member_env.deps; worker.stdlibs])]
    active === nothing || push!(plan, dirname(active) => wanted_versions(project_env.graph, selected))
    session, plan
end

"""
    maintain_environment!(worker)

Set this version's autoloads environment up from an older version's the first
time none is found, and apply changes other versions defer to it. A failure is
logged, with Pkg's output, and not retried until the deferred changes change.
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
    if !worker.has_tried_setup && !isfile(joinpath(worker.runtime.member, "Project.toml"))
        worker.has_tried_setup = true
        previous = quietly(output -> Autoloads.adopt_previous!(global_dir; output),
                           "set up the autoloads environment from an older Julia version's")
        previous === nothing ||
            @info "Autoloads set up its environment for Julia $(VERSION.major).$(VERSION.minor), carrying over \
                   $(join(previous.names, ", ")) and the settings from Julia $(VERSION.major).$(previous.minor)"
    end
    stamp = file_stamp(joinpath(state_dir(), Autoloads.DEFERRED_FILE))
    stamp == worker.deferred_stamp && return
    worker.deferred_stamp = stamp
    stamp == MISSING_FILE_STAMP ||
        quietly(output -> Autoloads.apply_deferred!(global_dir; output), "apply the changes made from other Julia versions")
end

"""
    warn_unknown_packages!(reported, cfg, autoload)

Warn, once each, of `packages.<Name>` settings for packages that do not autoload.
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
    read_config!(worker)

`load_config()`, or `nothing` after logging its `ConfigError` once.
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
    previous === nothing && await_first_refresh(runtime)
    session = @atomic SESSION.session
    if session === nothing ex else transform_statements(session, ex) end
end

"""
    await_first_refresh(runtime, timeout_s = FIRST_REFRESH_WAIT_S)

Wait, up to `timeout_s`, for the worker's first refresh: an input typed ahead
of the prompt would otherwise pass before there is a session.
"""
await_first_refresh(runtime::Runtime, timeout_s = FIRST_REFRESH_WAIT_S) =
    timedwait(() -> (@atomic runtime.has_refreshed), timeout_s; pollint = 0.005)

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
    env_stamp(runtime)

The active project, and the stamps of the files whose change calls for a refresh.
"""
function env_stamp(runtime::Runtime)
    active = Base.active_project()
    root_project = joinpath(dirname(runtime.member), "Project.toml")
    files = (root_project, manifest_of(root_project), preferences_files(root_project)...,
             joinpath(runtime.member, "Project.toml"), active, manifest_of(active), preferences_files(active)...)
    (; active, environment = map(file_stamp, files), catalog = file_stamp(runtime.catalog_path))
end

# ── Helpers ──

function load_pending!(session::Session, names)
    isbound(name) = isdefined(Main, name)
    for request in pending_loads(session.registry, session.config, names, isbound, Base.root_module_exists, LOAD.attempted)
        load!(LOAD, request, session.member; announce = session.config.log)
    end
end

"""
    is_unreported!(reported, err) -> Bool

Whether `err` has gone unlogged since `reported` was last emptied; it then has been.
"""
function is_unreported!(reported::Set{String}, err)
    message = sprint(showerror, err)
    message in reported && return false
    push!(reported, message)
    true
end

wanted_versions(graph::ManifestGraph, ids) =
    Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => get(graph.versions, id.uuid, nothing) for id in ids)

manifest_of(::Nothing) = nothing
manifest_of(project_file::String) = if isfile(project_file) Base.project_file_manifest_path(project_file) end

# The files Base reads preferences from beside `project_file`, besides itself.
preferences_files(::Nothing) = (nothing, nothing)
preferences_files(project_file::String) =
    (joinpath(dirname(project_file), "LocalPreferences.toml"), joinpath(dirname(project_file), "JuliaLocalPreferences.toml"))

file_stamp(::Nothing) = MISSING_FILE_STAMP

# A missing file's `stat` is all zeros: `MISSING_FILE_STAMP`.
function file_stamp(path::String)
    st = stat(path)
    (Float64(st.mtime), Int64(st.size), UInt64(st.inode))
end
