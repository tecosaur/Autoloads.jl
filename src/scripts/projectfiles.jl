# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Project files read and written as Pkg does. The including script binds `TOML`.

# Pkg's top-level key order, so rewritten files read as Pkg writes them.
const KEY_ORDER = ["name", "uuid", "keywords", "license", "desc", "version", "readonly", "workspace",
                   "deps", "weakdeps", "sources", "extensions", "compat"]

writetoml(path, dict) = writeatomically(path, sprint(io -> TOML.print(io, dict; sorted = true,
                                                                   by = key -> (something(findfirst(==(key), KEY_ORDER), length(KEY_ORDER) + 1), key))))

# A copy of the one in catalogfile.jl.
function writeatomically(path, content)
    tmp = path * ".tmp-$(getpid())"
    try
        write(tmp, content)
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
end

"""
    manifestsources(projectfile) -> Dict{String, Dict{String, Any}}

The `[sources]` entry for each developed or git-sourced package of `projectfile`'s manifest, by UUID.
"""
function manifestsources(projectfile)
    manifest = Base.project_file_manifest_path(projectfile)
    sources = Dict{String, Dict{String, Any}}()
    manifest === nothing && return sources
    for infos in values(get(TOML.parsefile(manifest), "deps", Dict{String, Any}())), info in infos
        source = if haskey(info, "path")
            Dict{String, Any}("path" => normpath(joinpath(dirname(manifest), info["path"])))
        elseif haskey(info, "repo-url")
            Dict{String, Any}(key => info["repo-" * key] for key in ("url", "rev", "subdir") if haskey(info, "repo-" * key))
        end
        source === nothing || (sources[info["uuid"]] = source)
    end
    sources
end

"""
    carrieddeps(projectfile) -> Dict{String, Any}

The `[deps]` of `projectfile`, with their `[compat]` and Julia's, and the
`[sources]` of those developed or from a git repository: the project's own
entry, else one made from its manifest (Pkg before 1.13 records sources there
only). Paths are made absolute, for use in another project.
"""
function carrieddeps(projectfile)
    project = TOML.parsefile(projectfile)
    deps = get(project, "deps", Dict{String, Any}())
    declared = get(project, "sources", Dict{String, Any}())
    recorded = manifestsources(projectfile)
    absolute(source) = if haskey(source, "path")
        merge(source, Dict("path" => normpath(joinpath(dirname(projectfile), source["path"]))))
    else
        source
    end
    sources = Dict{String, Any}(name => absolute(get(declared, name, recorded[uuid]))
                                for (name, uuid) in deps if haskey(declared, name) || haskey(recorded, uuid))
    compat = filter(((name, _),) -> name == "julia" || haskey(deps, name), get(project, "compat", Dict{String, Any}()))
    filter(((_, table),) -> !isempty(table), Dict{String, Any}("deps" => deps, "compat" => compat, "sources" => sources))
end
