"""
Autoloads: load packages on demand at the REPL.

Public surface: the catalog records ([`PkgNames`](@ref), [`PkgFailure`](@ref),
[`CatalogRecord`](@ref)) and the functions that extract, merge and
(de)serialise them.
"""
module Autoloads

public PkgNames, PkgFailure, CatalogRecord
public extract_names, merge_observation, catalog_line, parse_catalog_line

include("records.jl")

end
