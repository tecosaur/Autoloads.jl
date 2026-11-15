# Global autoloads environment setup, run by `Autoloads.init` as
#
#     julia --project=<global env> init.jl <global env dir> <member to carry over, or "">
#
# Lists the `autoloads` member in the global Project.toml's
# `[workspace].projects` (rewriting the file only when that changes it),
# creates the member with the `[deps]` and `[compat]` of the member carried
# over, if any, then resolves the workspace. A Pkg error is printed without
# a backtrace and exits 1.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
const MEMBER = "autoloads"
# Pkg's top-level key order, so rewritten files read as Pkg writes them.
const KEY_ORDER = ["name", "uuid", "keywords", "license", "desc", "version", "readonly", "workspace",
                   "deps", "weakdeps", "sources", "extensions", "compat"]

function main(global_dir, carry_over_dir)
    mkpath(global_dir)
    list_member(joinpath(global_dir, "Project.toml"))
    create_member(joinpath(global_dir, MEMBER, "Project.toml"), carry_over_dir)
    Pkg.resolve()
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
    carried = isempty(carry_over_dir) ? Dict{String, Any}() :
        filter(((key, _),) -> key in ("deps", "compat"), TOML.parsefile(joinpath(carry_over_dir, "Project.toml")))
    mkpath(dirname(member_file))
    write_toml(member_file, carried)
    println("Created $member_file",
            isempty(carry_over_dir) ? "" : ", carrying over $(length(get(carried, "deps", ()))) packages from $carry_over_dir")
end

key_rank(key) = (something(findfirst(==(key), KEY_ORDER), length(KEY_ORDER) + 1), key)

write_toml(path, dict) = open(io -> TOML.print(io, dict; sorted = true, by = key_rank), path, "w")

try
    main(ARGS[1], ARGS[2])
catch err
    err isa Pkg.Types.PkgError || rethrow()
    printstyled(stderr, "ERROR: "; bold = true, color = :red)
    println(stderr, err.msg)
    exit(1)
end
