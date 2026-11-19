# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# REPL integration: autoloads what input needs, hints providers on
# `UndefVarError`, and completes autoloadable names.
module AutoloadsREPLExt

using Autoloads, REPL, StyledStrings
using REPL: LineEdit
using Autoloads: Registry, LoadRequest, is_candidate, manifest_graph, dependency_closure,
    project_deps, environment
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Sighting, PrecompilePolicy, Lazy, Background,
    julia_command, write_catalog_changes!, CatalogTooNew, INTERRUPTED_EXIT_CODE, INDEXING_LOCK_SUFFIX, JULIA_MINOR
using Autoloads: Catalog, Config, ConfigError, ManifestGraph, build_catalog, build_registry, autoload_set,
    pending_loads, to_index, owner, names_at, read_catalog, read_healed_catalog,
    extract_names, stdlib_ids, builtin_records, member_dir, catalog_path, state_dir, load_config, parse_config

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
    backend = if isdefined(Base, :active_repl_backend) Base.active_repl_backend end
    backend !== nothing && hasproperty(backend, :ast_transforms) && push!(backend.ast_transforms, repl_transform)
    nothing
end

ccall(:jl_generating_output, Cint, ()) == 1 && include("workload.jl")

end
