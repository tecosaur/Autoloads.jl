# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# One worker task owns everything derived from the environments and catalog; the
# transform, load callbacks and change notifications only post events to it.

const MISSING_FILE_STAMP = (0.0, Int64(0), UInt64(0))
const STOP_WAIT_S = 2.0
const FIRST_REFRESH_WAIT_S = 2.0

struct Session
    catalog::Catalog
    registry::Registry
    config::Config
    member::String
    memberdeps::Set{String}
end

# Written only by the worker.
mutable struct SessionRef
    @atomic session::Union{Session, Nothing}
end

struct Refresh end

struct Observed
    id::Base.PkgId
end

struct Flush
    done::Channel{Nothing}
end

const Event = Union{Refresh, Observed, Flush}

# (mtime, size, inode) of each watched file.
const FileStamp = Tuple{Float64, Int64, UInt64}
# The catalog is apart: its changes call for a refresh, but not for retrying failed loads.
const EnvStamp = @NamedTuple{active::Union{String, Nothing}, environment::NTuple{9, FileStamp}, catalog::FileStamp}

mutable struct Runtime
    const events::Channel{Event}
    const member::String
    const catalogpath::String
    stamp::Union{EnvStamp, Nothing}  # owned by the REPL backend task
    @atomic isstopping::Bool
    @atomic hasrefreshed::Bool
end

Runtime(events::Channel{Event}, member::AbstractString, catalogpath::AbstractString) =
    Runtime(events, String(member), String(catalogpath), nothing, false, false)

mutable struct Worker
    const runtime::Runtime
    const indexer::Indexer
    const builtins::Vector{PkgNames}
    const stdlibs::Vector{Base.PkgId}
    const configerrors::Set{String}
    const observationerrors::Set{String}
    const refresherrors::Set{String}
    const unknownpackages::Set{String}
    triedsetup::Bool
    deferredstamp::FileStamp
end

Worker(runtime::Runtime, indexer::Indexer) =
    Worker(runtime, indexer, builtinrecords(), stdlibids(), Set{String}(), Set{String}(), Set{String}(),
           Set{String}(), false, MISSING_FILE_STAMP)

struct ObserveLoad
    events::Channel{Event}
end

(observe::ObserveLoad)(id::Base.PkgId) = (put!(observe.events, Observed(id)); nothing)

const SESSION = SessionRef(nothing)
const LOAD = LoadState()
const RUNTIME = Ref{Union{Runtime, Nothing}}(nothing)

function startsession!(; member::AbstractString = memberdir(), catalog::AbstractString = catalogpath())
    RUNTIME[] === nothing || return RUNTIME[]
    runtime = Runtime(Channel{Event}(Inf), member, catalog)
    events = runtime.events
    RUNTIME[] = runtime
    push!(Base.package_callbacks, ObserveLoad(events))
    Autoloads.ENV_CHANGED[] = () -> put!(events, Refresh())
    errormonitor(Threads.@spawn runworker(Worker(runtime, Indexer())))
    atexit(() -> stopworker!(runtime))
    put!(events, Refresh())
    runtime
end

"""
    stopworker!(runtime::Runtime)

Stop the worker and wait (up to $(STOP_WAIT_S) s) for its batch in progress:
exiting while it compiles or writes can crash the process.
"""
function stopworker!(runtime::Runtime)
    @atomic runtime.isstopping = true
    done = Channel{Nothing}(1)
    put!(runtime.events, Flush(done))
    timedwait(() -> isready(done), STOP_WAIT_S; pollint = 0.01)
    nothing
end

function repltransform(ex)
    runtime = RUNTIME[]
    (runtime === nothing || Base.active_module() !== Main) && return ex
    try
        transforminput(runtime, ex)
    catch err
        err isa InterruptException && rethrow()
        @error "Autoloads transform failed" exception = (err, catch_backtrace()) maxlog = 1
        ex
    end
end

function preparestatement(stmt)
    session = @atomic SESSION.session
    session === nothing && return nothing
    try
        loadpending!(session, statementmacros(stmt))
        # Lowering runs in the newest world, so macros just loaded expand.
        loadpending!(session, @something(helpquerynames(stmt),
                                          Base.invokelatest(undefinedglobals, stmt, Main)::Vector{Symbol}))
    catch err
        isinterrupt(err) && rethrow()
        @error "Autoloads failed to prepare a statement" exception = (err, catch_backtrace()) maxlog = 1
    end
    nothing
end

# The worker

function runworker(worker::Worker)
    (; events) = runtime = worker.runtime
    for event in events
        batch = Event[event]
        while isready(events)
            push!(batch, take!(events))
        end
        try
            (@atomic runtime.isstopping) || handlebatch!(worker, batch)
        catch err
            @error "Autoloads failed to update its session" exception = (err, catch_backtrace())
        finally
            foreach(flush -> put!(flush.done, nothing), (e for e in batch if e isa Flush))
        end
    end
end

function handlebatch!(worker::Worker, batch::Vector{Event})
    observed = unique(event.id for event in batch if event isa Observed)
    haswritten = try
        written = observe!(worker, observed)
        isempty(observed) || empty!(worker.observationerrors)
        written
    catch err
        isunreported!(worker.observationerrors, err) &&
            @error "Autoloads failed to record loaded packages in its catalog" packages = observed exception =
                (err, catch_backtrace())
        false
    end
    (haswritten || any(event -> event isa Refresh, batch)) || return
    try
        maintainenvironment!(worker)
        session, plan = derivesession(worker)
        @atomic SESSION.session = session
        if session !== nothing
            @debug "Autoloads session refreshed" names = length(session.registry.owners) catalog = length(session.catalog.records)
            indexnext!(worker, session.config.policy, session.catalog, plan)
        end
        empty!(worker.refresherrors)
    catch err
        isunreported!(worker.refresherrors, err) &&
            @error "Autoloads failed to update its session" exception = (err, catch_backtrace())
    finally
        @atomic worker.runtime.hasrefreshed = true
    end
    nothing
end

function observe!(worker::Worker, ids)
    records = CatalogRecord[]
    for id in ids
        id.uuid === nothing && continue
        record = Base.invokelatest(extractnames, Base.root_module(id), id)
        # Extensions offer no names beyond their own.
        ownnameonly = isempty(record.public) && isempty(record.reexported) && length(record.exported) == 1
        ownnameonly || push!(records, record)
    end
    isempty(records) && return false
    try
        writecatalog!(worker.runtime.catalogpath, records)
    catch err
        err isa CatalogTooNew || rethrow()
        false  # `derivesession` warns of it
    end
end

function derivesession(worker::Worker)
    cfg = readconfig!(worker)
    cfg === nothing && return nothing, nothing
    member = worker.runtime.member
    memberproject = joinpath(member, "Project.toml")
    active = Base.active_project()
    memberenv, projectenv = environment(memberproject), environment(active)
    selected = [id for id in projectenv.deps if isselected(cfg, id.name)]
    hasmember = isfile(memberproject)
    hasmember || !isempty(selected) || return nothing, nothing
    autoload = autoloadset(memberenv.deps, memberenv.graph, projectenv.deps, projectenv.graph,
                            worker.stdlibs, [record.id for record in worker.builtins], cfg)
    warnunknown!(worker.unknownpackages, cfg, autoload)
    records = try
        readhealedcatalog(worker.runtime.catalogpath)
    catch err
        err isa CatalogTooNew || rethrow()
        @warn "Autoloads is off" exception = err maxlog = 1
        return nothing, nothing
    end
    catalog = buildcatalog(append!(convert(Vector{CatalogRecord}, worker.builtins), records))
    session = Session(catalog, buildregistry(catalog, autoload, cfg), cfg, member,
                      Set(id.name for id in memberenv.deps))
    # Stdlibs are always indexed, for hints. Without a member, a session implies an active project.
    plan = [if hasmember member else dirname(active::String) end =>
                wantedversions(memberenv.graph, [memberenv.deps; worker.stdlibs])]
    active === nothing || push!(plan, dirname(active) => wantedversions(projectenv.graph, selected))
    session, plan
end

"""
    maintainenvironment!(worker::Worker)

Set this version's autoloads environment up from an older version's the first
time none is found, and apply changes other versions defer to it. A failure is
logged, with Pkg's output, and not retried until the deferred changes change.
"""
function maintainenvironment!(worker::Worker)
    globaldir = dirname(worker.runtime.member)
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
    if !worker.triedsetup && !isfile(joinpath(worker.runtime.member, "Project.toml"))
        worker.triedsetup = true
        previous = quietly(output -> Autoloads.adoptprevious!(globaldir; output),
                           "set up the autoloads environment from an older Julia version's")
        previous === nothing ||
            @info "Autoloads set up its environment for Julia $(VERSION.major).$(VERSION.minor), carrying over \
                   $(join(previous.names, ", ")) and the settings from Julia $(VERSION.major).$(previous.minor)"
    end
    stamp = filestamp(joinpath(statedir(), Autoloads.DEFERRED_FILE))
    stamp == worker.deferredstamp && return
    worker.deferredstamp = stamp
    stamp == MISSING_FILE_STAMP ||
        quietly(output -> Autoloads.applydeferred!(globaldir; output), "apply the changes made from other Julia versions")
end

function warnunknown!(reported::Set{String}, cfg::Config, autoload::AbstractDict)
    unknown = setdiff(keys(cfg.packages), (id.name for id in keys(autoload)))
    newlyunknown = sort!(collect(setdiff(unknown, reported)))
    isempty(newlyunknown) ||
        @warn "Autoloads has settings for packages it does not autoload here: $(join(newlyunknown, ", ")). \
               Check the `packages` names in [preferences.Autoloads], or add them with `pkg> autoloads add`."
    empty!(reported)
    union!(reported, unknown)
end

function readconfig!(worker::Worker)
    try
        cfg = loadconfig()
        empty!(worker.configerrors)
        cfg
    catch err
        err isa ConfigError || rethrow()
        isunreported!(worker.configerrors, err) &&
            @error "Autoloads is off until its settings are fixed" exception = err
        nothing
    end
end

function indexnext!(worker::Worker, policy::PrecompilePolicy, catalog::Catalog, plan)
    for (project, wanted) in plan
        missingids = unindexed(catalog, wanted)
        isempty(missingids) && continue
        pairs = Pair{Base.PkgId, Union{VersionNumber, Nothing}}[id => wanted[id] for id in missingids]
        events = worker.runtime.events
        startindexing!(worker.indexer, policy, project, worker.runtime.catalogpath, pairs,
                        changed -> changed && put!(events, Refresh()))
        return
    end
end

# The transform

function transforminput(runtime::Runtime, ex)
    active = Base.active_project()
    rootproject = joinpath(dirname(runtime.member), "Project.toml")
    files = (rootproject, manifestof(rootproject), preferencefiles(rootproject)...,
             joinpath(runtime.member, "Project.toml"), active, manifestof(active), preferencefiles(active)...)
    stamp = (; active, environment = map(filestamp, files), catalog = filestamp(runtime.catalogpath))
    previous = runtime.stamp
    # `===`, as later loads invalidate a generic `!=` on the stamps.
    sameenv = previous !== nothing && stamp.active == previous.active &&
        stamp.environment === previous.environment
    if !sameenv || stamp.catalog !== previous.catalog
        runtime.stamp = stamp
        sameenv || forgetfailures!(LOAD)
        put!(runtime.events, Refresh())
    end
    previous === nothing && awaitfirstrefresh(runtime)
    session = @atomic SESSION.session
    if session === nothing ex else transformstatements(session, ex) end
end

"""
    awaitfirstrefresh(runtime::Runtime, timeout_s = FIRST_REFRESH_WAIT_S)

Wait, up to `timeout_s`, for the worker's first refresh: an input typed ahead
of the prompt would otherwise pass before there is a session.
"""
awaitfirstrefresh(runtime::Runtime, timeout_s = FIRST_REFRESH_WAIT_S) =
    timedwait(() -> (@atomic runtime.hasrefreshed), timeout_s; pollint = 0.005)

function transformstatements(session::Session, ex)
    memberonly(root::Symbol) =
        String(root) in session.memberdeps && Base.identify_package(String(root)) === nothing
    mapstatements(ex) do stmt
        iscandidatestatement(session.registry, stmt, memberonly) || return stmt
        anyunquoted(node -> ismemberonlyimport(node, memberonly), stmt) &&
            return Expr(:call, GlobalRef(@__MODULE__, :evalwithmember), QuoteNode(stmt), session.member)
        Expr(:toplevel, Expr(:call, GlobalRef(@__MODULE__, :preparestatement), QuoteNode(stmt)), stmt)
    end
end

# Utility functions

function loadpending!(session::Session, names)
    isbound(name) = isdefined(Main, name)
    for request in pendingloads(session.registry, session.config, names, isbound, Base.root_module_exists, LOAD.attempted)
        load!(LOAD, request, session.member; announce = session.config.log)
    end
end

function isunreported!(reported::Set{String}, err)
    message = sprint(showerror, err)
    message in reported && return false
    push!(reported, message)
    true
end

wantedversions(graph::ManifestGraph, ids) =
    Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => get(graph.versions, id.uuid, nothing) for id in ids)

manifestof(::Nothing) = nothing
manifestof(projectfile::String) = if isfile(projectfile) Base.project_file_manifest_path(projectfile) end

# The files Base reads preferences from beside `projectfile`, besides itself.
preferencefiles(::Nothing) = (nothing, nothing)
preferencefiles(projectfile::String) =
    (joinpath(dirname(projectfile), "LocalPreferences.toml"), joinpath(dirname(projectfile), "JuliaLocalPreferences.toml"))

filestamp(::Nothing) = MISSING_FILE_STAMP

# A missing file's `stat` is all zeros: `MISSING_FILE_STAMP`.
function filestamp(path::String)
    st = stat(path)
    (Float64(st.mtime), Int64(st.size), UInt64(st.inode))
end
