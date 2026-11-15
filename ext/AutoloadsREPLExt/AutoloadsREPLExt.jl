"""
REPL integration for Autoloads: scans REPL input for references that an
autoload package could satisfy, and indexes packages in a supervised
subprocess.
"""
module AutoloadsREPLExt

using Autoloads, REPL
using Autoloads: Registry, LoadRequest, is_candidate, manifest_graph, dependency_closure
using Autoloads: PkgFailure, CatalogRecord, PrecompilePolicy, Lazy, Background,
    run_julia, write_catalog_changes!, INTERRUPTED_EXIT_CODE

include("scan.jl")
include("indexer.jl")
include("load.jl")

end
