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
    pending_loads, to_index, owner, names_at, read_catalog, read_healed_catalog, extract_names, stdlib_ids, builtin_records, member_dir,
    catalog_path, load_config, parse_config

include("scan.jl")
include("indexer.jl")
include("load.jl")
include("session.jl")
include("hints.jl")
include("complete.jl")

function __init__()
    isinteractive() || return
    start_session!()
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
    backend = isdefined(Base, :active_repl_backend) ? Base.active_repl_backend : nothing
    backend !== nothing && hasproperty(backend, :ast_transforms) && push!(backend.ast_transforms, repl_transform)
    nothing
end

# Precompile workload: the transform's pure core on inline data. Cached code
# costs load time, so only what the first input runs is compiled here.
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
    # First TAB: the wrapper's merge, and the wrapper itself on the REPL's types.
    for (text, region) in (("wl", 0 => 2), ("Workload.w", 9 => 10))
        with_autoloadable((LineEdit.NamedCompletion[LineEdit.NamedCompletion("w")], region, true), session, text)
    end
    precompile(Core.kwcall, (@NamedTuple{hint::Bool}, typeof(LineEdit.complete_line),
                             CompletionWrapper{REPL.REPLCompletionProvider}, LineEdit.PromptState, Module))
    precompile(Tuple{ObserveLoad, Base.PkgId})
    precompile(repl_transform, (Expr,))
    precompile(env_stamp, (Runtime,))
    precompile(prepare_statement, (Expr,))
    precompile(load_pending!, (Session, Vector{Symbol}))
    # `LoadState.attempted` keys are concrete tuples at run time.
    for key in (Tuple{Base.PkgId, Nothing}, Tuple{Base.PkgId, Symbol})
        precompile(in, (key, Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}))
        precompile(push!, (Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}, key))
    end
end

end
