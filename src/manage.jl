# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Management commands: set up the global autoloads environment (the
# `autoloads` workspace member of the global environment), change its
# packages through Pkg in subprocesses, so this session's environment stays
# untouched, and report what autoloads.

const PKG_SUBPROCESS_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)
const SCRIPTS_DIR = joinpath(@__DIR__, "scripts")
# In a version's `state_dir`: one `resolve`, or `update [pkg ...]`, per line
# (`scripts/spread.jl` appends `resolve` lines too).
const DEFERRED_FILE = "deferred"

"""
    PkgOperationFailed(op, pkgs, env, exitcode)

The Pkg subprocess of management command `op` (`:init`, `:add`, `:remove`,
`:update` or `:resolve`) on packages `pkgs`, in environment directory `env`,
exited with `exitcode`. Its output, already printed, gives the reason.
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
whether to copy its `[deps]` with their `[compat]` and `[sources]` (developed
and git-sourced packages keep their source), and the Autoloads preferences
of that environment's Project.toml and LocalPreferences.toml into each of
this one's that has none: `true`, `false`, or `:ask` to prompt in
interactive sessions (otherwise, print how to add them).

Warns if the global environment does not depend on Autoloads. The
`global_dir` keyword is internal, for testing.

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
    previous = if !isfile(joinpath(member_dir(global_dir), "Project.toml")) previous_member(global_dir) end
    is_carried = previous !== nothing && if carry_over === :ask ask_carry_over(previous) else carry_over end
    create_environment(global_dir, if is_carried previous.dir else "" end)
end

"""
    add(pkgs::Vector{String}; all_versions = false)
    add(pkgs::AbstractString...; all_versions = false)

Add packages to the global autoloads environment, first creating it with
[`init`](@ref) if it does not exist yet: paths of existing directories are
developed, git URLs (`url#rev` for a revision) are added from their
repository, and names from the registries. Recorded indexing failures of
the packages are cleared, so they are indexed again. With `all_versions`,
the packages are also added, with the same source and compat, to the
autoloads environment of every other Julia version that has one, each
resolving it when its Julia next starts a REPL session.
The `global_dir` and `catalog` keywords are internal, for testing.

# Raises
- `ArgumentError` when `pkgs` is empty.
- [`PkgOperationFailed`](@ref) when Pkg fails.

# Example
```julia
Autoloads.add("Example")
```
"""
function add(pkgs::Vector{String}; all_versions::Bool = false, global_dir::AbstractString = global_env_dir(),
             catalog::AbstractString = catalog_path())
    isempty(pkgs) && throw(ArgumentError("Autoloads.add: no packages given"))
    member = member_dir(global_dir)
    member_project = joinpath(member, "Project.toml")
    isfile(member_project) || init(; global_dir)
    specs = [if isdir(expanduser(pkg)) abspath(expanduser(pkg)) else pkg end for pkg in pkgs]
    before = Set(project_deps(member_project))
    # A failed `Pkg.add` may follow a successful `Pkg.develop`, so notify regardless.
    try
        run_pkg_operation(:add, pkgs, specs, member)
        names = [if isdir(spec) package_name(spec) else spec end for spec in specs]
        added = [id for id in project_deps(member_project) if id.name in names || id ∉ before]
        clear_failures!(catalog, added)
        all_versions && spread!(:add, global_dir, [id.name for id in added])
    finally
        notify_env_change()
    end
end

add(pkgs::AbstractString...; kwargs...) = add(collect(String, pkgs); kwargs...)

"""
    remove(pkgs::Vector{String}; all_versions = false)
    remove(pkgs::AbstractString...; all_versions = false)

Remove the packages named `pkgs` from the global autoloads environment.
With `all_versions`, also remove them from the autoloads environment of
every other Julia version, each resolving it when its Julia next starts a
REPL session; packages this version lacks are then not an error.
The `global_dir` keyword is internal, for testing.

# Raises
- `ArgumentError` when `pkgs` is empty.
- [`MemberMissing`](@ref) before [`init`](@ref) has run.
- [`PkgOperationFailed`](@ref) when Pkg fails, e.g. for a package it lacks.

# Example
```julia
Autoloads.remove("Example")
```
"""
function remove(pkgs::Vector{String}; all_versions::Bool = false, global_dir::AbstractString = global_env_dir())
    isempty(pkgs) && throw(ArgumentError("Autoloads.remove: no packages given"))
    member = existing_member(global_dir)
    names = Set(id.name for id in project_deps(joinpath(member, "Project.toml")))
    present = if all_versions filter(in(names), pkgs) else pkgs end
    isempty(present) || run_pkg_operation(:remove, present, present, member)
    all_versions && spread!(:remove, global_dir, pkgs)
    notify_env_change()
end

remove(pkgs::AbstractString...; kwargs...) = remove(collect(String, pkgs); kwargs...)

"""
    update(pkgs::Vector{String} = String[]; all_versions = false)
    update(pkgs::AbstractString...; all_versions = false)

Update the packages named `pkgs` of the global environment and its
autoloads member, or all of their packages when `pkgs` is empty, in one
resolve of the shared manifest. With `all_versions`, every other Julia
version with an autoloads environment does the same when it next starts a
REPL session. The `global_dir` keyword is internal, for testing.

# Raises
- [`MemberMissing`](@ref) before [`init`](@ref) has run.
- [`PkgOperationFailed`](@ref) when Pkg fails.

# Example
```julia
Autoloads.update()
```
"""
function update(pkgs::Vector{String} = String[]; all_versions::Bool = false,
                global_dir::AbstractString = global_env_dir())
    existing_member(global_dir)
    run_pkg_operation(:update, pkgs, pkgs, global_dir)
    if all_versions
        for member in version_members(global_dir)
            member.dir == member_dir(global_dir) || defer!(member.version, "update", pkgs)
        end
    end
    notify_env_change()
end

update(pkg::AbstractString, pkgs::AbstractString...; kwargs...) = update(String[pkg, pkgs...]; kwargs...)

"""
    status(io::IO = stdout)

Print what autoloads: the global autoload packages, then those of the active
project, each with its version and whether it is `indexed (n names)` (`n`
names to autoload), `not indexed`, or `failed: <reason>`; then the names
that more than one package claims, the precompile policy and the global
autoloads environment's path. Reads the environments and the catalog afresh.
The `global_dir` and `catalog` keywords are internal, for testing.

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
    print_autoloads(io, if active === nothing "Project autoloads:" else "Project autoloads ($active):" end,
                    project_env.graph, selected, cat, cfg)
    ambiguous = sort!(collect(ambiguities(build_registry(cat, autoload, cfg))); by = first)
    println(io, "Ambiguous names:", if isempty(ambiguous) " none" else "" end)
    for (name, ids) in ambiguous
        println(io, "  ", name, ": ", join(sort!([id.name for id in ids]), ", "))
    end
    println(io, "Precompile policy: ", lowercase(string(cfg.policy)))
    println(io, "Autoloads environment: ", member,
            if isfile(member_project) "" else " (missing; create it with `pkg> autoloads init`)" end)
end

# ── Helpers ──

"""
The autoloads member of the newest older Julia minor's global environment
beside `global_dir`, with its dependencies: `(; minor, dir, names)`, or
`nothing` when there is none with dependencies.
"""
function previous_member(global_dir::AbstractString)
    older = filter(member -> member.version.major == VERSION.major && member.version.minor < VERSION.minor,
                   version_members(global_dir))
    isempty(older) && return nothing
    (; version, dir) = argmax(member -> member.version, older)
    names = sort!([id.name for id in project_deps(joinpath(dir, "Project.toml"))])
    if !isempty(names); (; minor = Int(version.minor), dir, names) end
end

"""
The `(; version, dir)` of each autoloads member of the global environments
of every Julia version beside `global_dir`, its own included.
"""
function version_members(global_dir::AbstractString)
    parent = dirname(global_dir)
    members = @NamedTuple{version::VersionNumber, dir::String}[]
    isdir(parent) || return members
    for name in readdir(parent)
        version = match(r"^v(\d+)\.(\d+)$", name)
        dir = joinpath(parent, name, "autoloads")
        version === nothing || !isfile(joinpath(dir, "Project.toml")) ||
            push!(members, (; version = VersionNumber(parse(Int, version[1]), parse(Int, version[2])), dir))
    end
    members
end

"""
Make `op` (`:add` or `:remove`) of packages `names` in the autoloads members
of the other Julia versions beside `global_dir` (by `scripts/spread.jl`),
deferring a resolve to each version whose member it changes.
"""
function spread!(op::Symbol, global_dir::AbstractString, names::Vector{String})
    source = member_dir(global_dir)
    targets = [(member.dir, joinpath(state_dir(member.version), DEFERRED_FILE))
               for member in version_members(global_dir) if member.dir != source]
    isempty(targets) && return
    run_pkg_subprocess(op, names, `$(joinpath(SCRIPTS_DIR, "spread.jl")) $op $source $(join(names, ',')) \
                                   $(collect(Iterators.flatten(targets)))`; project = source)
end

"Defer `op` (`resolve`, or `update` of `pkgs`, all when empty) on Julia `version`'s autoloads environment."
function defer!(version::VersionNumber, op::AbstractString, pkgs::Vector{String} = String[])
    path = joinpath(state_dir(version), DEFERRED_FILE)
    mkpath(dirname(path))
    open(io -> println(io, join([op; pkgs], ' ')), path, "a")
end

"""
    apply_deferred!(global_dir; output = stdout) -> Bool

Apply the changes other Julia versions deferred to this one's autoloads
environment in `global_dir` (see [`defer!`](@ref)) in one resolve, or one
update if any asked for one; whether there were any. Pkg prints to `output`.

Raises [`PkgOperationFailed`](@ref), leaving the deferred changes in place.
"""
function apply_deferred!(global_dir::AbstractString; output::IO = stdout)
    path = joinpath(state_dir(), DEFERRED_FILE)
    isfile(path) || return false
    content = read(path, String)
    requests = split.(split(content, '\n'; keepempty = false))
    updates = [String.(request[2:end]) for request in requests if first(request) == "update"]
    if isempty(updates)
        run_pkg_operation(:resolve, String[], String[], global_dir; output)
    else
        pkgs = if any(isempty, updates) String[] else unique!(reduce(vcat, updates)) end
        run_pkg_operation(:update, pkgs, pkgs, global_dir; output)
    end
    read(path, String) == content && rm(path)
    notify_env_change()
    true
end

"""
    adopt_previous!(global_dir; output = stdout) -> Union{NamedTuple, Nothing}

Create this Julia version's autoloads environment in `global_dir` from the
newest older version's, carrying its packages and settings over without
asking: that version's [`previous_member`](@ref), or `nothing` (and nothing
done) if there is none. Pkg prints to `output`.
"""
function adopt_previous!(global_dir::AbstractString; output::IO = stdout)
    previous = previous_member(global_dir)
    previous === nothing || create_environment(global_dir, previous.dir; output)
    previous
end

"Run `scripts/init.jl` in `global_dir`, carrying over the member `source` (`\"\"` for none)."
function create_environment(global_dir::AbstractString, source::AbstractString; output::IO = stdout)
    run_pkg_subprocess(:init, String[], `$(joinpath(SCRIPTS_DIR, "init.jl")) $global_dir $source`;
                       project = global_dir, output)
    autoloads_uuid = Base.PkgId(@__MODULE__).uuid
    any(id -> id.uuid == autoloads_uuid, project_deps(joinpath(global_dir, "Project.toml"))) ||
        @warn "The global environment ($global_dir) does not depend on Autoloads, so `using Autoloads` \
               will not find it there; run `pkg> add Autoloads` with the global environment active"
    notify_env_change()
end

"Whether to carry over `previous`: the user's answer, or (non-interactive) `false` after saying how."
function ask_carry_over(previous)
    count = length(previous.names)
    packages, them = if count == 1; ("package", "it") else ("packages", "them") end
    julia = "Julia $(VERSION.major).$(previous.minor)"
    if isinteractive()
        print(stdout, "Carry over $count autoload $packages, and the Autoloads settings, from $julia? [Y/n] ")
        return lowercase(strip(readline(stdin))) in ("", "y", "yes")
    end
    println(stdout, "$julia has $count autoload $packages ($(join(previous.names, ", "))); to carry ",
            them, " over, run `pkg> autoloads add $(join(previous.names, ' '))`")
    false
end

function existing_member(global_dir::AbstractString)
    member = member_dir(global_dir)
    isfile(joinpath(member, "Project.toml")) || throw(MemberMissing(member))
    member
end

"Run `scripts/pkg.jl` for `op` with `args` in environment `project`."
run_pkg_operation(op::Symbol, pkgs::Vector{String}, args::Vector{String}, project::AbstractString; output::IO = stdout) =
    run_pkg_subprocess(op, pkgs, `$(joinpath(SCRIPTS_DIR, "pkg.jl")) $op $args`; project, output)

function run_pkg_subprocess(op::Symbol, pkgs::Vector{String}, args::Cmd; project::AbstractString, output::IO = stdout)
    process = run_julia(args; project, env = PKG_SUBPROCESS_ENV, output)
    wait(process)
    @debug "Autoloads Pkg subprocess exited" op pkgs project process.exitcode
    success(process) || throw(PkgOperationFailed(op, pkgs, String(project), process.exitcode))
    nothing
end

function package_name(dir::AbstractString)
    project = joinpath(dir, "Project.toml")
    if isfile(project) get(Base.parsed_toml(project), "name", nothing) end
end

function print_autoloads(io::IO, title, graph::ManifestGraph, ids, cat::Catalog, cfg::Config)
    println(io, title)
    isempty(ids) && return println(io, "  (none)")
    entries = map(sort(ids; by = id -> id.name)) do id
        version = get(graph.versions, id.uuid, nothing)
        (if version === nothing id.name else "$(id.name) v$version" end, index_state(cat, cfg, id, version))
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
    if failure === nothing "not indexed" else "failed: " * first(split(failure.message, '\n')) end
end
