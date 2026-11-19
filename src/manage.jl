# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Management commands, run through Pkg in subprocesses so this session's
# environment is untouched.

const PKG_SUBPROCESS_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)
const SCRIPTS_DIR = joinpath(@__DIR__, "scripts")
# In a version's `state_dir`: one `resolve`, or `update [pkg ...]`, per line.
const DEFERRED_FILE = "deferred"
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")

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
- `ErrorException` when setting up or resolving fails; Pkg's output gives the reason.

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
`init` if it does not exist yet: paths of existing directories are
developed, git URLs (`url#rev` for a revision) are added from their
repository, and names from the registries. Recorded indexing failures of
the packages are cleared, so they are indexed again. With `all_versions`,
the packages are also added, with the same source and compat, to the
autoloads environment of every other Julia version that has one, each
resolving it when its Julia next starts a REPL session.
The `global_dir` and `catalog` keywords are internal, for testing.

# Raises
- `ArgumentError` when `pkgs` is empty.
- `ErrorException` when Pkg fails; its output gives the reason.
- `CatalogTooNew` when the catalog is in a newer format, after Pkg has added the packages.

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
- `ErrorException` before `init` has run, or when Pkg fails (e.g. for a package it lacks).

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
- `ErrorException` before `init` has run, or when Pkg fails.

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
    status([io::IO,] pkgs::AbstractString...)

Print what autoloads: the global autoload packages, then those of the active
project, each with its version and either its exports (the names that
autoload) and public names, `not indexed`, or `failed: <reason>`; then the
names that more than one package claims (which do not autoload), and the
precompile policy.

Given the names of autoload packages (standard libraries included), print
for each what becomes of the names it offers: those that autoload it, those
other packages also claim, the re-exports that load their owner instead,
those the `skip` and `only` settings exclude, and its public names.

Reads the environments and the catalog afresh, and loads Pkg, whose
extension renders the report. The `global_dir` and `catalog` keywords are
internal, for testing.

# Raises
- `ConfigError` when the Autoloads preferences are invalid.
- `CatalogTooNew` when the catalog is in a newer format.
- `ArgumentError` for a package that does not autoload here.

# Example
```julia
Autoloads.status()
Autoloads.status("Statistics")
```
"""
function status(io::IO = stdout, pkgs::AbstractString...; global_dir::AbstractString = global_env_dir(),
                catalog::AbstractString = catalog_path())
    autoloads = read_autoloads(global_dir, catalog)
    Base.require(PKG_ID)
    Base.invokelatest(print_status, io, autoloads, pkgs...)
end

status(pkg::AbstractString, pkgs::AbstractString...; kwargs...) = status(stdout, pkg, pkgs...; kwargs...)

"""
    print_status(io, autoloads, pkgs...)

Print the `status` report of `autoloads`, as `read_autoloads` gives it. Its
methods are in the Pkg extension.
"""
function print_status end

# ── Helpers ──

"""
    previous_member(global_dir)

The newest older Julia minor's autoloads member beside `global_dir`, as
`(; minor, dir, names)`, or `nothing` if it has no packages.
"""
function previous_member(global_dir::AbstractString)
    older = filter(member -> member.version.major == VERSION.major && member.version.minor < VERSION.minor,
                   version_members(global_dir))
    isempty(older) && return nothing
    (; version, dir) = argmax(member -> member.version, older)
    names = sort!([id.name for id in project_deps(joinpath(dir, "Project.toml"))])
    if !isempty(names); (; minor = Int(version.minor), dir, names) end
end

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
    spread!(op, global_dir, names)

Make `op` (`:add` or `:remove`) of `names` in the other Julia versions'
members, deferring a resolve to each one changed.
"""
function spread!(op::Symbol, global_dir::AbstractString, names::Vector{String})
    source = member_dir(global_dir)
    targets = [member for member in version_members(global_dir) if member.dir != source]
    isempty(targets) && return
    project_text(member) = read(joinpath(member.dir, "Project.toml"), String)
    before = map(project_text, targets)
    try
        run_pkg_subprocess(op, names, `$(joinpath(SCRIPTS_DIR, "spread.jl")) $op $source $(join(names, ',')) \
                                       $([member.dir for member in targets])`; project = source)
    finally
        for (member, text) in zip(targets, before)
            project_text(member) == text || defer!(member.version, "resolve")
        end
    end
end

"""
    defer!(version, op, pkgs = String[])

Queue `op` (`resolve`, or `update` of `pkgs`, all if none) for Julia `version`.
"""
function defer!(version::VersionNumber, op::AbstractString, pkgs::Vector{String} = String[])
    path = joinpath(state_dir(version), DEFERRED_FILE)
    with_file_lock(() -> open(io -> println(io, join([op; pkgs], ' ')), path, "a"), path)
end

"""
    apply_deferred!(global_dir; output = stdout) -> Bool

Apply the changes other Julia versions deferred to this one, in one resolve or
update. Returns whether there were any; on failure they stay queued.
"""
function apply_deferred!(global_dir::AbstractString; output::IO = stdout)
    path = joinpath(state_dir(), DEFERRED_FILE)
    isfile(path) || return false
    content = with_file_lock(() -> read(path, String), path)
    requests = split.(split(content, '\n'; keepempty = false))
    updates = [String.(request[2:end]) for request in requests if first(request) == "update"]
    if isempty(updates)
        run_pkg_operation(:resolve, String[], String[], global_dir; output)
    else
        pkgs = if any(isempty, updates) String[] else unique!(reduce(vcat, updates)) end
        run_pkg_operation(:update, pkgs, pkgs, global_dir; output)
    end
    drop_applied!(path, content)
    notify_env_change()
    true
end

"""
    drop_applied!(path, applied)

Remove `applied` from the start of the deferred file at `path`, keeping lines appended since.
"""
function drop_applied!(path::AbstractString, applied::AbstractString)
    with_file_lock(path) do
        isfile(path) || return
        rest = chopprefix(read(path, String), applied)
        if isempty(rest) rm(path) else write(path, rest) end
    end
end

"""
    adopt_previous!(global_dir; output = stdout) -> Union{NamedTuple, Nothing}

Create this version's autoloads environment from the newest older one's,
without asking. Returns that version's `previous_member`, or `nothing`.
"""
function adopt_previous!(global_dir::AbstractString; output::IO = stdout)
    previous = previous_member(global_dir)
    previous === nothing || create_environment(global_dir, previous.dir; output)
    previous
end

function create_environment(global_dir::AbstractString, source::AbstractString; output::IO = stdout)
    run_pkg_subprocess(:init, String[], `$(joinpath(SCRIPTS_DIR, "init.jl")) $global_dir $source`;
                       project = global_dir, output)
    autoloads_uuid = Base.PkgId(@__MODULE__).uuid
    any(id -> id.uuid == autoloads_uuid, project_deps(joinpath(global_dir, "Project.toml"))) ||
        @warn "The global environment ($global_dir) does not depend on Autoloads, so `using Autoloads` \
               will not find it there; run `pkg> add Autoloads` with the global environment active"
    notify_env_change()
end

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
    isfile(joinpath(member, "Project.toml")) ||
        error("There is no autoloads environment at $member; create it with `pkg> autoloads init` ",
              "(or `Autoloads.init()`), then try again.")
    member
end

run_pkg_operation(op::Symbol, pkgs::Vector{String}, args::Vector{String}, project::AbstractString; output::IO = stdout) =
    run_pkg_subprocess(op, pkgs, `$(joinpath(SCRIPTS_DIR, "pkg.jl")) $op $args`; project, output)

function run_pkg_subprocess(op::Symbol, pkgs::Vector{String}, args::Cmd; project::AbstractString, output::IO = stdout)
    process = run_julia(args; project, env = PKG_SUBPROCESS_ENV, output)
    wait(process)
    @debug "Autoloads Pkg subprocess exited" op pkgs project process.exitcode
    success(process) ||
        error("Autoloads.$op failed", if isempty(pkgs) "" else " for $(join(pkgs, ", "))" end, " in $project: ",
              "its Pkg subprocess exited with code $(process.exitcode). The Pkg output above gives the reason; ",
              "fix that and try again.")
    nothing
end

function package_name(dir::AbstractString)
    project = joinpath(dir, "Project.toml")
    if isfile(project) get(Base.parsed_toml(project), "name", nothing) end
end

function read_autoloads(global_dir::AbstractString, catalog::AbstractString)
    cfg = load_config()
    member = member_dir(global_dir)
    member_env = environment(joinpath(member, "Project.toml"))
    active = Base.active_project()
    project_env = environment(active)
    builtins = builtin_records()
    cat = build_catalog([builtins; read_catalog(catalog)])
    autoload = autoload_set(member_env.deps, member_env.graph, project_env.deps, project_env.graph,
                            stdlib_ids(), [record.id for record in builtins], cfg)
    (; cfg, member, member_env, active, project_env, cat, autoload, registry = build_registry(cat, autoload, cfg))
end
