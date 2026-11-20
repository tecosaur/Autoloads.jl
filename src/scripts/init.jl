# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Run by `Autoloads.init` as
#
#     julia --project=<global env> init.jl <global env dir> <member to carry over, or "">
#
# Lists, creates and resolves the `autoloads` member, undoing it all on failure.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
const MEMBER = "autoloads"

include("projectfiles.jl")

function main(globaldir, carrydir)
    mkpath(globaldir)
    projectfile = joinpath(globaldir, "Project.toml")
    memberfile = joinpath(globaldir, MEMBER, "Project.toml")
    originals = [file => if isfile(file) read(file) end
                 for file in (projectfile, joinpath(globaldir, "LocalPreferences.toml"))]
    haddir, hadfile = isdir(dirname(memberfile)), isfile(memberfile)
    try
        listmember(projectfile)
        createmember(memberfile, carrydir)
        isempty(carrydir) || carrypreferences(globaldir, dirname(carrydir))
        Pkg.resolve()
    catch
        for (file, original) in originals
            if original === nothing
                rm(file; force = true)
            else
                writeatomically(file, original)
            end
        end
        haddir || rm(dirname(memberfile); recursive = true, force = true)
        haddir && !hadfile && rm(memberfile; force = true)
        println(stderr, "Restored $projectfile and removed the new $MEMBER member after the failure below")
        rethrow()
    end
end

# Steps

function listmember(projectfile)
    project = if isfile(projectfile) TOML.parsefile(projectfile) else Dict{String, Any}() end
    projects = get!(get!(project, "workspace", Dict{String, Any}()), "projects", String[])
    if MEMBER in projects
        println("$projectfile already lists the $MEMBER workspace member")
    else
        push!(projects, MEMBER)
        writetoml(projectfile, project)
        println("Added the $MEMBER workspace member to $projectfile")
    end
end

function createmember(memberfile, carrydir)
    isfile(memberfile) && return println("$memberfile already exists")
    mkpath(dirname(memberfile))
    if isempty(carrydir)
        writetoml(memberfile, Dict{String, Any}())
        println("Created $memberfile")
    else
        carried = carrieddeps(joinpath(carrydir, "Project.toml"))
        writetoml(memberfile, carried)
        println("Created $memberfile, carrying over $(length(get(carried, "deps", ()))) packages from $carrydir")
    end
end

function carrypreferences(globaldir, previousdir)
    for (file, keypath) in (("Project.toml", ["preferences", "Autoloads"]), ("LocalPreferences.toml", ["Autoloads"]))
        source = joinpath(previousdir, file)
        isfile(source) || continue
        table = foldl((dict, key) -> get(dict, key, Dict{String, Any}()), keypath; init = TOML.parsefile(source))
        isempty(table) && continue
        target = joinpath(globaldir, file)
        content = if isfile(target) TOML.parsefile(target) else Dict{String, Any}() end
        parent = foldl((dict, key) -> get!(dict, key, Dict{String, Any}()), keypath[1:end-1]; init = content)
        haskey(parent, last(keypath)) && continue
        parent[last(keypath)] = table
        writetoml(target, content)
        println("Carried over the Autoloads preferences in $source")
    end
end

try
    main(ARGS[1], ARGS[2])
catch err
    err isa Union{Pkg.Types.PkgError, Pkg.Resolve.ResolverError} || rethrow()
    printstyled(stderr, "ERROR: "; bold = true, color = :red)
    println(stderr, err.msg)
    exit(1)
end
