# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Global autoloads environment setup, run by `Autoloads.init` as
#
#     julia --project=<global env> init.jl <global env dir> <member to carry over, or "">
#
# Lists the `autoloads` member in the global Project.toml's workspace,
# creates it (with the packages and Autoloads preferences of the member
# carried over, if any) and resolves. A failure restores the files changed and
# removes what was created, so `init` can be run again; a Pkg or resolver
# error is printed without a backtrace and exits 1.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
const MEMBER = "autoloads"

include("projectfiles.jl")

function main(global_dir, carry_over_dir)
    mkpath(global_dir)
    project_file = joinpath(global_dir, "Project.toml")
    member_file = joinpath(global_dir, MEMBER, "Project.toml")
    originals = [file => if isfile(file) read(file) end
                 for file in (project_file, joinpath(global_dir, "LocalPreferences.toml"))]
    had_member_dir, had_member_file = isdir(dirname(member_file)), isfile(member_file)
    try
        list_member(project_file)
        create_member(member_file, carry_over_dir)
        isempty(carry_over_dir) || carry_preferences(global_dir, dirname(carry_over_dir))
        Pkg.resolve()
    catch
        for (file, original) in originals
            if original === nothing
                rm(file; force = true)
            else
                write_atomically(file, original)
            end
        end
        had_member_dir || rm(dirname(member_file); recursive = true, force = true)
        had_member_dir && !had_member_file && rm(member_file; force = true)
        println(stderr, "Restored $project_file and removed the new $MEMBER member after the failure below")
        rethrow()
    end
end

# ── Helpers ──

function list_member(project_file)
    project = if isfile(project_file) TOML.parsefile(project_file) else Dict{String, Any}() end
    projects = get!(get!(project, "workspace", Dict{String, Any}()), "projects", String[])
    if MEMBER in projects
        println("$project_file already lists the $MEMBER workspace member")
    else
        push!(projects, MEMBER)
        write_toml(project_file, project)
        println("Added the $MEMBER workspace member to $project_file")
    end
end

function create_member(member_file, carry_over_dir)
    isfile(member_file) && return println("$member_file already exists")
    mkpath(dirname(member_file))
    if isempty(carry_over_dir)
        write_toml(member_file, Dict{String, Any}())
        println("Created $member_file")
    else
        carried = carried_deps(joinpath(carry_over_dir, "Project.toml"))
        write_toml(member_file, carried)
        println("Created $member_file, carrying over $(length(get(carried, "deps", ()))) packages from $carry_over_dir")
    end
end

"""
Copy the Autoloads preferences of the global environment in `previous_dir`,
from its Project.toml and LocalPreferences.toml, into each of
`global_dir`'s that has none.
"""
function carry_preferences(global_dir, previous_dir)
    for (file, keypath) in (("Project.toml", ["preferences", "Autoloads"]), ("LocalPreferences.toml", ["Autoloads"]))
        source = joinpath(previous_dir, file)
        isfile(source) || continue
        table = foldl((dict, key) -> get(dict, key, Dict{String, Any}()), keypath; init = TOML.parsefile(source))
        isempty(table) && continue
        target = joinpath(global_dir, file)
        content = if isfile(target) TOML.parsefile(target) else Dict{String, Any}() end
        parent = foldl((dict, key) -> get!(dict, key, Dict{String, Any}()), keypath[1:end-1]; init = content)
        haskey(parent, last(keypath)) && continue
        parent[last(keypath)] = table
        write_toml(target, content)
        println("Carried over the Autoloads preferences in $source")
    end
end

"""
The `[deps]` of `project_file`, with their `[compat]` and Julia's, and the
`[sources]` of those developed or from a git repository: the project's own
entry, else one made from its manifest (Pkg before 1.13 records sources there
only). Paths are made absolute, as the new member is elsewhere.
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

try
    main(ARGS[1], ARGS[2])
catch err
    err isa Union{Pkg.Types.PkgError, Pkg.Resolve.ResolverError} || rethrow()
    printstyled(stderr, "ERROR: "; bold = true, color = :red)
    println(stderr, err.msg)
    exit(1)
end
