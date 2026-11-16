# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
REPL integration for Autoloads: scans REPL input for references that an
autoload package could satisfy, loads those packages just before the
statements that need them, and keeps the catalog current by observing loads
and indexing packages in a supervised subprocess, all coordinated by one
session worker (see `session.jl`). Also suggests providers on `UndefVarError`
(`hints.jl`) and completes autoloadable names (`complete.jl`).
"""
module AutoloadsREPLExt

using Autoloads, REPL
using REPL: LineEdit
using Autoloads: Registry, LoadRequest, is_candidate, manifest_graph, dependency_closure,
    project_deps, environment
using Autoloads: PkgNames, PkgFailure, CatalogRecord, PrecompilePolicy, Lazy, Background,
    julia_command, write_catalog_changes!, INTERRUPTED_EXIT_CODE
using Autoloads: Catalog, Config, ConfigError, ManifestGraph, build_catalog, build_registry, autoload_set,
    pending_loads, to_index, owner, names_at, read_catalog, read_healed_catalog,
    extract_names, stdlib_ids, builtin_records, member_dir, catalog_path, state_dir, load_config, parse_config

const WORKER_START_POLL_S = 0.05
const WORKER_START_FALLBACK_S = 5
const IS_COMPILATION_SERIALISED = VERSION < v"1.14-"

include("scan.jl")
include("indexer.jl")
include("load.jl")
include("session.jl")
include("hints.jl")
include("complete.jl")

function __init__()
    isinteractive() || return
    # The worker starts at the first prompt, so as not to slow the REPL's start.
    is_repl_running = isdefined(Base, :active_repl)
    runtime = start_session!(; is_deferred = !is_repl_running)
    if !is_repl_running
        start = WorkerStart(runtime)
        atreplinit(start)
        Timer(start, WORKER_START_FALLBACK_S)
    end
    install_transform()
    install_completion()
    Base.Experimental.register_error_hint(undefvar_hint, UndefVarError)
end

# The one place that touches REPL internals: `repl_ast_transforms` is copied
# by each new backend, and a backend already running keeps its own list.
function install_transform()
    if !isdefined(REPL, :repl_ast_transforms)
        @warn "Autoloads cannot hook into this REPL (no `REPL.repl_ast_transforms`); autoloading is off"
        return
    end
    push!(REPL.repl_ast_transforms, repl_transform)
    backend = if isdefined(Base, :active_repl_backend) Base.active_repl_backend end
    backend !== nothing && hasproperty(backend, :ast_transforms) && push!(backend.ast_transforms, repl_transform)
    nothing
end

# Precompile workload: what inputs and the first prompt run, and the worker
# where its compiling would stall the REPL's. Cached code costs load time.
let id = Base.PkgId(Base.UUID("0b1b2b3b-4444-4555-8666-777788889999"), "Workload")
    records = CatalogRecord[PkgNames(id, [v"1.0.0"], Set([:Workload, :wl, Symbol("@wl")]), Set([:wp]), Set{Symbol}())]
    catalog = build_catalog(records)
    cfg = parse_config(Dict{String, Any}())
    reg = build_registry(catalog, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => v"1.0.0"), cfg)
    session = Session(catalog, reg, cfg, "", Set{String}())
    input = REPL.softscope(Base.parse_input_line("x = 1; y = [wl(x), Workload.wp(2)]; @wl f(z) = wl(z)"))
    transform_statements(session, input)
    for stmt in input.args[end].args
        statement_macros(stmt)
        undefined_globals(stmt, @__MODULE__)
    end
    owner(reg, :wl)
    for (text, region) in (("wl", 0 => 2), ("Workload.w", 9 => 10))
        with_autoloadable((LineEdit.NamedCompletion[LineEdit.NamedCompletion("w")], region, true), session, text)
    end
    precompile(Core.kwcall, (@NamedTuple{hint::Bool}, typeof(LineEdit.complete_line),
                             CompletionWrapper{REPL.REPLCompletionProvider}, LineEdit.PromptState, Module))
    precompile(Tuple{ObserveLoad, Base.PkgId})
    precompile(repl_transform, (Expr,))
    transform_input(Runtime(Channel{Event}(Inf), "", ""), :(1))
    @static if IS_COMPILATION_SERIALISED
        precompile(Worker, (Runtime, Indexer))
        precompile(run_worker, (Worker,))
        # Run for real: `precompile` misses what untyped settings and TOML dispatch to.
        mktempdir() do dir
            member = joinpath(dir, "autoloads")
            mkpath(member)
            write(joinpath(member, "Project.toml"), "[deps]\nWorkload = \"$(id.uuid)\"\n")
            write_catalog_changes!(joinpath(dir, "catalog"), [records; PkgFailure(id, v"0.9.0", "failed")])
            parse_config(Dict{String, Any}("project" => ["Workload"], "packages" => Dict{String, Any}(
                "Workload" => Dict{String, Any}("skip" => ["wl"], "only" => ["wp"], "bindings" => "used"))))
            worker = Worker(Runtime(Channel{Event}(Inf), member, joinpath(dir, "catalog")), Indexer())
            # The user's settings are read, and may not suit this member.
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                derive_session(worker)
                maintain_environment!(worker)
                observe!(worker, [Base.PkgId(Autoloads)])
            end
        end
    end
    let start = WorkerStart(Runtime(Channel{Event}(Inf), "", ""))
        precompile(start, (REPL.LineEditREPL,))
        wait(Timer(start, 0))
    end
    precompile(prepare_statement, (Expr,))
    precompile(wrap_completion!, (REPL.LineEditREPL,))
    precompile(Tuple{Type{CompletionWrapper}, REPL.REPLCompletionProvider})
    precompile(load_pending!, (Session, Vector{Symbol}))
    # `LoadState.attempted` keys are concrete tuples at run time.
    for key in (Tuple{Base.PkgId, Nothing}, Tuple{Base.PkgId, Symbol})
        precompile(in, (key, Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}))
        precompile(push!, (Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}, key))
    end
end

end
