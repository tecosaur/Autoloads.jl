# Management commands: set up the global autoloads environment (the
# `autoloads` workspace member of the global environment), change its
# packages through Pkg in subprocesses, so this session's environment stays
# untouched, and report what autoloads.

const PKG_SUBPROCESS_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)
const SCRIPTS_DIR = joinpath(@__DIR__, "scripts")

"""
    PkgOperationFailed(op, pkgs, env, exitcode)

The Pkg subprocess of management command `op` (`:init`, `:add`, `:remove`
or `:update`) on packages `pkgs`, in environment directory `env`, exited
with `exitcode`. Its output, already printed, gives the reason.
"""
struct PkgOperationFailed <: Exception
    op::Symbol
    pkgs::Vector{String}
    env::String
    exitcode::Int
end

function Base.showerror(io::IO, e::PkgOperationFailed)
    print(io, "Autoloads.", e.op, " failed")
    isempty(e.pkgs) || print(io, " for ", join(e.pkgs, ", "))
    print(io, " in ", e.env, ": its Pkg subprocess exited with code ", e.exitcode, ". ",
          "The Pkg output above gives the reason; fix that and try again.")
end

"""
    MemberMissing(member)

A management command needs the autoloads environment `member`, which has
not been created.
"""
struct MemberMissing <: Exception
    member::String
end

Base.showerror(io::IO, e::MemberMissing) =
    print(io, "There is no autoloads environment at ", e.member, "; ",
          "create it with `pkg> autoloads init` (or `Autoloads.init()`), then try again.")

"""
    init(; carry_over = :ask)

Set up the global autoloads environment: list `"autoloads"` in the global
environment's `[workspace].projects`, create the `autoloads` member, and
resolve the workspace. Running it again changes nothing. Adding the member
re-serialises the global Project.toml, keeping its content but (as Pkg's own
writes do) not its comments or layout. If resolving fails, the global
Project.toml is restored and the new member removed.

When the member is created and the global environment of an older Julia
minor version (the newest one) has an autoloads member, `carry_over` says
whether to copy its registry `[deps]` and their `[compat]`: `true`, `false`,
or `:ask` to prompt in interactive sessions (otherwise, print how to add
them). Developed and git-sourced packages are not carried over; their names
are printed so they can be re-added by path.

Warns if the global environment does not depend on Autoloads.

# Raises
- `ArgumentError` for any other `carry_over`.
- [`PkgOperationFailed`](@ref) when setting up or resolving fails.

# Example
```julia
Autoloads.init(carry_over = false)
```
"""
function init(; carry_over::Union{Bool, Symbol} = :ask, global_dir::AbstractString = global_env_dir())
    carry_over isa Bool || carry_over === :ask ||
        throw(ArgumentError("Autoloads.init: `carry_over` must be true, false or :ask, not $(repr(carry_over))"))
    previous = isfile(joinpath(member_dir(global_dir), "Project.toml")) ? nothing : previous_member(global_dir)
    is_carried = previous !== nothing && (carry_over === :ask ? ask_carry_over(previous) : carry_over)
    source = is_carried ? previous.dir : ""
    run_pkg_subprocess(:init, String[], `$(joinpath(SCRIPTS_DIR, "init.jl")) $global_dir $source`;
                       project = global_dir)
    autoloads_uuid = Base.PkgId(@__MODULE__).uuid
    any(id -> id.uuid == autoloads_uuid, project_deps(joinpath(global_dir, "Project.toml"))) ||
        @warn "The global environment ($global_dir) does not depend on Autoloads, so `using Autoloads` \
               will not find it there; run `pkg> add Autoloads` with the global environment active"
    notify_env_change()
end

"""
    add(pkgs::Vector{String})

Add packages to the global autoloads environment: names are added from the
registries, and paths of existing directories are developed. Recorded
indexing failures of the packages are cleared, so they are indexed again.

# Raises
- `ArgumentError` when `pkgs` is empty.
- [`MemberMissing`](@ref) before [`init`](@ref) has run.
- [`PkgOperationFailed`](@ref) when Pkg fails.

# Example
```julia
Autoloads.add(["Example"])
```
"""
function add(pkgs::Vector{String}; global_dir::AbstractString = global_env_dir(),
             catalog::AbstractString = catalog_path())
    isempty(pkgs) && throw(ArgumentError("Autoloads.add: no packages given"))
    member = existing_member(global_dir)
    specs = [isdir(expanduser(pkg)) ? abspath(expanduser(pkg)) : pkg for pkg in pkgs]
    # A failed `Pkg.add` may follow a successful `Pkg.develop`, so notify regardless.
    try
        run_pkg_operation(:add, pkgs, specs, member)
        names = [isdir(spec) ? package_name(spec) : spec for spec in specs]
        clear_failures!(catalog, [id for id in project_deps(joinpath(member, "Project.toml")) if id.name in names])
    finally
        notify_env_change()
    end
end

"""
    remove(pkgs::Vector{String})

Remove the packages named `pkgs` from the global autoloads environment.

# Raises
- `ArgumentError` when `pkgs` is empty.
- [`MemberMissing`](@ref) before [`init`](@ref) has run.
- [`PkgOperationFailed`](@ref) when Pkg fails, e.g. for a package it lacks.

# Example
```julia
Autoloads.remove(["Example"])
```
"""
function remove(pkgs::Vector{String}; global_dir::AbstractString = global_env_dir())
    isempty(pkgs) && throw(ArgumentError("Autoloads.remove: no packages given"))
    run_pkg_operation(:remove, pkgs, pkgs, existing_member(global_dir))
    notify_env_change()
end

"""
    update(pkgs::Vector{String} = String[])

Update the packages named `pkgs` of the global environment and its
autoloads member, or all of their packages when `pkgs` is empty, in one
resolve of the shared manifest.

# Raises
- [`MemberMissing`](@ref) before [`init`](@ref) has run.
- [`PkgOperationFailed`](@ref) when Pkg fails.

# Example
```julia
Autoloads.update()
```
"""
function update(pkgs::Vector{String} = String[]; global_dir::AbstractString = global_env_dir())
    existing_member(global_dir)
    run_pkg_operation(:update, pkgs, pkgs, global_dir)
    notify_env_change()
end

"""
    status(io::IO = stdout)

Print what autoloads: the global autoload packages, then those of the active
project, each with its version and whether it is `indexed (n names)` (`n`
names to autoload), `not indexed`, or `failed: <reason>`; then the names
that more than one package claims, the precompile policy and the global
autoloads environment's path. Reads the environments and the catalog afresh.

# Raises
[`ConfigError`](@ref) when the Autoloads preferences are invalid.

# Example
```julia
Autoloads.status()
```
"""
function status(io::IO = stdout; global_dir::AbstractString = global_env_dir(),
                catalog::AbstractString = catalog_path())
    cfg = load_config()
    member = member_dir(global_dir)
    member_project = joinpath(member, "Project.toml")
    member_env = environment(member_project)
    active = Base.active_project()
    project_env = environment(active)
    selected = [id for id in project_env.deps if cfg.project === nothing || id.name in cfg.project]
    builtins = builtin_records()
    cat = build_catalog([builtins; read_catalog(catalog)])
    autoload = autoload_set(member_env.deps, member_env.graph, project_env.deps, project_env.graph,
                            stdlib_ids(), [record.id for record in builtins], cfg)
    print_autoloads(io, "Global autoloads:", member_env.graph, member_env.deps, cat, cfg)
    print_autoloads(io, active === nothing ? "Project autoloads:" : "Project autoloads ($active):",
                    project_env.graph, selected, cat, cfg)
    ambiguous = sort!(collect(ambiguities(build_registry(cat, autoload, cfg))); by = first)
    println(io, "Ambiguous names:", isempty(ambiguous) ? " none" : "")
    for (name, ids) in ambiguous
        println(io, "  ", name, ": ", join(sort!([id.name for id in ids]), ", "))
    end
    println(io, "Precompile policy: ", lowercase(string(cfg.policy)))
    println(io, "Autoloads environment: ", member,
            isfile(member_project) ? "" : " (missing; create it with `pkg> autoloads init`)")
end

# ── Helpers ──

"""
The autoloads member of the newest older Julia minor's global environment
beside `global_dir`, with its dependencies: `(; minor, dir, names)`, or
`nothing` when there is none with dependencies.
"""
function previous_member(global_dir::AbstractString)
    parent = dirname(global_dir)
    prefix = "v$(VERSION.major)."
    minors = Int[]
    for name in (isdir(parent) ? readdir(parent) : String[])
        minor = startswith(name, prefix) ? tryparse(Int, chopprefix(name, prefix)) : nothing
        minor !== nothing && minor < VERSION.minor &&
            isfile(joinpath(parent, name, "autoloads", "Project.toml")) && push!(minors, minor)
    end
    isempty(minors) && return nothing
    minor = maximum(minors)
    dir = joinpath(parent, prefix * string(minor), "autoloads")
    names = sort!([id.name for id in project_deps(joinpath(dir, "Project.toml"))])
    isempty(names) ? nothing : (; minor, dir, names)
end

"Whether to carry over `previous`: the user's answer, or (non-interactive) `false` after saying how."
function ask_carry_over(previous)
    count = length(previous.names)
    packages = count == 1 ? "package" : "packages"
    julia = "Julia $(VERSION.major).$(previous.minor)"
    if isinteractive()
        print(stdout, "Carry over $count autoload $packages from $julia? [Y/n] ")
        return lowercase(strip(readline(stdin))) in ("", "y", "yes")
    end
    println(stdout, "$julia has $count autoload $packages ($(join(previous.names, ", "))); to carry ",
            count == 1 ? "it" : "them", " over, run `pkg> autoloads add $(join(previous.names, ' '))`")
    false
end

function existing_member(global_dir::AbstractString)
    member = member_dir(global_dir)
    isfile(joinpath(member, "Project.toml")) || throw(MemberMissing(member))
    member
end

"Run `scripts/pkg.jl` for `op` with `args` in environment `project`."
run_pkg_operation(op::Symbol, pkgs::Vector{String}, args::Vector{String}, project::AbstractString) =
    run_pkg_subprocess(op, pkgs, `$(joinpath(SCRIPTS_DIR, "pkg.jl")) $op $args`; project)

function run_pkg_subprocess(op::Symbol, pkgs::Vector{String}, args::Cmd; project::AbstractString)
    process = run_julia(args; project, env = PKG_SUBPROCESS_ENV)
    wait(process)
    @debug "Autoloads Pkg subprocess exited" op pkgs project process.exitcode
    success(process) || throw(PkgOperationFailed(op, pkgs, String(project), process.exitcode))
    nothing
end

function package_name(dir::AbstractString)
    project = joinpath(dir, "Project.toml")
    isfile(project) ? get(Base.parsed_toml(project), "name", nothing) : nothing
end

function print_autoloads(io::IO, title, graph::ManifestGraph, ids, cat::Catalog, cfg::Config)
    println(io, title)
    isempty(ids) && return println(io, "  (none)")
    entries = map(sort(ids; by = id -> id.name)) do id
        version = get(graph.versions, id.uuid, nothing)
        (version === nothing ? id.name : "$(id.name) v$version", index_state(cat, cfg, id, version))
    end
    width = maximum(textwidth ∘ first, entries)
    for (label, state) in entries
        println(io, "  ", rpad(label, width), "  ", state)
    end
end

function index_state(cat::Catalog, cfg::Config, id::Base.PkgId, version)
    record = names_at(cat, id, version)
    record === nothing || return "indexed ($(length(autoload_names(record, package_config(cfg, id.name)))) names)"
    failure = failed_at(cat, id, version)
    failure === nothing ? "not indexed" : "failed: " * first(split(failure.message, '\n'))
end
