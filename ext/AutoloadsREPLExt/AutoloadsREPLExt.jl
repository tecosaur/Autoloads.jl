"""
REPL integration for Autoloads: scans REPL input for references that an
autoload package could satisfy.
"""
module AutoloadsREPLExt

using Autoloads, REPL
using Autoloads: Registry, is_candidate

include("scan.jl")

end
