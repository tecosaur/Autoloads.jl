"""
REPL integration for Autoloads: scans REPL input for references that an
autoload package could satisfy, and indexes packages in a supervised
subprocess.
"""
module AutoloadsREPLExt

using Autoloads, REPL
using Autoloads: Registry, is_candidate
using Autoloads: PkgFailure, CatalogRecord, PrecompilePolicy, Lazy, Background,
    run_julia, write_catalog_changes!

include("scan.jl")
include("indexer.jl")

end
