# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# REPL integration: autoloads what input needs, hints providers on
# `UndefVarError`, and completes autoloadable names.
module AutoloadsREPLExt

using Autoloads, REPL, StyledStrings
using REPL: LineEdit
using Autoloads: Registry, LoadRequest, iscandidate, manifestgraph, dependencyclosure,
    projectdeps, environment
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Sighting, PrecompilePolicy, Lazy, Background,
    juliacmd, writecatalog!, CatalogTooNew, INTERRUPTED_EXIT_CODE, INDEXING_LOCK_SUFFIX, JULIA_MINOR
using Autoloads: Catalog, Config, ConfigError, ManifestGraph, Session, buildcatalog, buildregistry,
    pendingloads, unindexed, owner, namesat, readcatalog, readhealedcatalog,
    extractnames, stdlibids, builtinrecords, memberdir, catalogpath, statedir, loadconfig, parseconfig

include("scan.jl")
include("indexer.jl")
include("load.jl")
include("session.jl")
include("hints.jl")
include("complete.jl")

function __init__()
    isinteractive() || return
    startsession!()
    installtransform()
    installcompletion()
    Base.Experimental.register_error_hint(undefvarhint, UndefVarError)
end

# The one place that touches REPL internals: `repl_ast_transforms` is copied
# by each new backend, and a backend already running keeps its own list.
function installtransform()
    if !isdefined(REPL, :repl_ast_transforms)
        @warn "Autoloads cannot hook into this REPL (no `REPL.repl_ast_transforms`); autoloading is off"
        return
    end
    push!(REPL.repl_ast_transforms, repltransform)
    backend = if isdefined(Base, :active_repl_backend) Base.active_repl_backend end
    backend !== nothing && hasproperty(backend, :ast_transforms) && push!(backend.ast_transforms, repltransform)
    nothing
end

ccall(:jl_generating_output, Cint, ()) == 1 && include("workload.jl")

end
