# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Project files read and written as Pkg does. The including script binds `TOML`.

# Pkg's top-level key order, so rewritten files read as Pkg writes them.
const KEY_ORDER = ["name", "uuid", "keywords", "license", "desc", "version", "readonly", "workspace",
                   "deps", "weakdeps", "sources", "extensions", "compat"]

key_rank(key) = (something(findfirst(==(key), KEY_ORDER), length(KEY_ORDER) + 1), key)

write_toml(path, dict) = write_atomically(path, sprint(io -> TOML.print(io, dict; sorted = true, by = key_rank)))

function write_atomically(path, content)
    tmp = path * ".tmp-$(getpid())"
    try
        write(tmp, content)
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
end

"The `[sources]` entry for each developed or git-sourced package of `project_file`'s manifest, by UUID."
function manifest_sources(project_file)
    manifest = Base.project_file_manifest_path(project_file)
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
The `[deps]` of `project_file`, with their `[compat]` and Julia's, and the
`[sources]` of those developed or from a git repository: the project's own
entry, else one made from its manifest (Pkg before 1.13 records sources there
only). Paths are made absolute, for use in another project.
"""
function carried_deps(project_file)
    project = TOML.parsefile(project_file)
    deps = get(project, "deps", Dict{String, Any}())
    declared = get(project, "sources", Dict{String, Any}())
    recorded = manifest_sources(project_file)
    absolute(source) = if haskey(source, "path")
        merge(source, Dict("path" => normpath(joinpath(dirname(project_file), source["path"]))))
    else
        source
    end
    sources = Dict{String, Any}(name => absolute(get(declared, name, recorded[uuid]))
                                for (name, uuid) in deps if haskey(declared, name) || haskey(recorded, uuid))
    compat = filter(((name, _),) -> name == "julia" || haskey(deps, name), get(project, "compat", Dict{String, Any}()))
    filter(((_, table),) -> !isempty(table), Dict{String, Any}("deps" => deps, "compat" => compat, "sources" => sources))
end
