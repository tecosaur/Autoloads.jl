# Global autoloads environment setup, run by `Autoloads.init` as
#
#     julia --project=<global env> init.jl <global env dir> <member to carry over, or "">
#
# Lists the `autoloads` member in the global Project.toml's
# `[workspace].projects` (rewriting the file, atomically, only when that
# changes it), creates the member with the registry `[deps]` (and their
# `[compat]`) of the member carried over, if any, then resolves the
# workspace. If anything fails, the global Project.toml is restored and what
# this run created of the member is removed, so `init` can simply be run
# again. A Pkg or resolver error is printed without a backtrace and exits 1.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
const MEMBER = "autoloads"
# Pkg's top-level key order, so rewritten files read as Pkg writes them.
const KEY_ORDER = ["name", "uuid", "keywords", "license", "desc", "version", "readonly", "workspace",
                   "deps", "weakdeps", "sources", "extensions", "compat"]

function main(global_dir, carry_over_dir)
    mkpath(global_dir)
    project_file = joinpath(global_dir, "Project.toml")
    member_file = joinpath(global_dir, MEMBER, "Project.toml")
    original = isfile(project_file) ? read(project_file) : nothing
    had_member_dir, had_member_file = isdir(dirname(member_file)), isfile(member_file)
    try
        list_member(project_file)
        create_member(member_file, carry_over_dir)
        Pkg.resolve()
    catch
        original === nothing ? rm(project_file; force = true) : write_atomically(project_file, original)
        had_member_dir || rm(dirname(member_file); recursive = true, force = true)
        had_member_dir && !had_member_file && rm(member_file; force = true)
        println(stderr, "Restored $project_file and removed the new $MEMBER member after the failure below")
        rethrow()
    end
end

# ── Helpers ──

function list_member(project_file)
    project = isfile(project_file) ? TOML.parsefile(project_file) : Dict{String, Any}()
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
    carried = isempty(carry_over_dir) ? Dict{String, Any}() : registry_deps(joinpath(carry_over_dir, "Project.toml"))
    mkpath(dirname(member_file))
    write_toml(member_file, carried)
    println("Created $member_file",
            isempty(carry_over_dir) ? "" : ", carrying over $(length(get(carried, "deps", ()))) packages from $carry_over_dir")
end

"""
The `[deps]` of `project_file` that its manifest does not record as developed
or git-sourced (with a `path` or `repo-url`), with their `[compat]` and
Julia's. Prints the names of the deps skipped.
"""
function registry_deps(project_file)
    project = TOML.parsefile(project_file)
    deps = get(project, "deps", Dict{String, Any}())
    sourced = sourced_uuids(project_file)
    kept = filter(((_, uuid),) -> !(uuid in sourced), deps)
    compat = filter(((name, _),) -> name == "julia" || haskey(kept, name), get(project, "compat", Dict{String, Any}()))
    skipped = sort!([name for name in keys(deps) if !haskey(kept, name)])
    isempty(skipped) ||
        println("Not carrying over $(join(skipped, ", ")), developed or from a git repository; ",
                "re-add each with `pkg> autoloads add <path>`")
    filter(((_, table),) -> !isempty(table), Dict{String, Any}("deps" => kept, "compat" => compat))
end

function sourced_uuids(project_file)
    manifest = Base.project_file_manifest_path(project_file)
    manifest === nothing && return Set{String}()
    entries = get(TOML.parsefile(manifest), "deps", Dict{String, Any}())
    Set{String}(info["uuid"] for infos in values(entries) for info in infos
                if haskey(info, "path") || haskey(info, "repo-url"))
end

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

try
    main(ARGS[1], ARGS[2])
catch err
    err isa Union{Pkg.Types.PkgError, Pkg.Resolve.ResolverError} || rethrow()
    printstyled(stderr, "ERROR: "; bold = true, color = :red)
    println(stderr, err.msg)
    exit(1)
end
