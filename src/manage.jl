# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Management commands, run through Pkg in subprocesses so this session's
# environment is untouched.

const PKG_SUBPROCESS_ENV = ("JULIA_PKG_PRECOMPILE_AUTO" => "0",)
const SCRIPTS_DIR = joinpath(@__DIR__, "scripts")
# In a version's `statedir`: one `resolve`, or `update [pkg ...]`, per line.
const DEFERRED_FILE = "deferred"
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")

"""
    init(; carryover::Union{Bool, Symbol} = :ask)

Set up the global autoloads environment: list `"autoloads"` in the global
environment's `[workspace].projects`, create the `autoloads` member, and
resolve the workspace. Running it again changes nothing. Adding the member
re-serialises the global Project.toml, keeping its content but (as Pkg's own
writes do) not its comments or layout. If resolving fails, the global
Project.toml is restored and the new member removed.

When the member is created and the global environment of an older Julia
minor version (the newest one) has an autoloads member, `carryover` says
whether to copy its `[deps]` with their `[compat]` and `[sources]` (developed
and git-sourced packages keep their source), and the Autoloads preferences
of that environment's Project.toml and LocalPreferences.toml into each of
this one's that has none: `true`, `false`, or `:ask` to prompt in
interactive sessions (otherwise, print how to add them).

Warns if the global environment does not depend on Autoloads.

# Raises
- `ArgumentError` for any other `carryover`.
- `ErrorException` when setting up or resolving fails; Pkg's output gives the reason.

# Example
```julia
Autoloads.init(carryover = false)
```
"""
function init(; carryover::Union{Bool, Symbol} = :ask)
    globaldir = globalenvdir()
    carryover isa Bool || carryover === :ask ||
        throw(ArgumentError("Autoloads.init: `carryover` must be true, false or :ask, not $(repr(carryover))"))
    previous = if !isfile(joinpath(memberdir(globaldir), "Project.toml")) previousmember(globaldir) end
    iscarried = previous !== nothing && if carryover === :ask askcarryover(previous) else carryover::Bool end
    createenvironment(globaldir, if iscarried previous.dir else "" end)
end

"""
    add(pkgs::Vector{String}; allversions = false)
    add(pkgs::AbstractString...; allversions = false)

Add packages to the global autoloads environment, first creating it with
`init` if it does not exist yet: paths of existing directories are
developed, git URLs (`url#rev` for a revision) are added from their
repository, and names from the registries. Recorded indexing failures of
the packages are cleared, so they are indexed again. With `allversions`,
the packages are also added, with the same source and compat, to the
autoloads environment of every other Julia version that has one, each
resolving it when its Julia next starts a REPL session.

# Raises
- `ArgumentError` when `pkgs` is empty.
- `ErrorException` when Pkg fails; its output gives the reason.
- `CatalogTooNew` when the catalog is in a newer format, after Pkg has added the packages.

# Example
```julia
Autoloads.add("Example")
```
"""
function add(pkgs::Vector{String}; allversions::Bool = false)
    isempty(pkgs) && throw(ArgumentError("Autoloads.add: no packages given"))
    projectname(dir) = if isfile(joinpath(dir, "Project.toml")) get(Base.parsed_toml(joinpath(dir, "Project.toml")), "name", nothing) end
    globaldir = globalenvdir()
    member = memberdir(globaldir)
    memberproject = joinpath(member, "Project.toml")
    isfile(memberproject) || init()
    specs = [if isdir(expanduser(pkg)) abspath(expanduser(pkg)) else pkg end for pkg in pkgs]
    before = Set(projectdeps(memberproject))
    # A failed `Pkg.add` may follow a successful `Pkg.develop`, so notify regardless.
    try
        runpkg(:add, pkgs, specs, member)
        names = [if isdir(spec) projectname(spec) else spec end for spec in specs]
        added = [id for id in projectdeps(memberproject) if id.name in names || id ∉ before]
        clearfailures!(catalogpath(), added)
        allversions && spread!(:add, globaldir, [id.name for id in added])
    finally
        notifyenvchange()
    end
end

add(pkgs::AbstractString...; kwargs...) = add(collect(String, pkgs); kwargs...)

"""
    remove(pkgs::Vector{String}; allversions = false)
    remove(pkgs::AbstractString...; allversions = false)

Remove the packages named `pkgs` from the global autoloads environment.
With `allversions`, also remove them from the autoloads environment of
every other Julia version, each resolving it when its Julia next starts a
REPL session; packages this version lacks are then not an error.

# Raises
- `ArgumentError` when `pkgs` is empty.
- `ErrorException` before `init` has run, or when Pkg fails (e.g. for a package it lacks).

# Example
```julia
Autoloads.remove("Example")
```
"""
function remove(pkgs::Vector{String}; allversions::Bool = false)
    isempty(pkgs) && throw(ArgumentError("Autoloads.remove: no packages given"))
    globaldir = globalenvdir()
    member = existingmember(globaldir)
    names = Set(id.name for id in projectdeps(joinpath(member, "Project.toml")))
    present = if allversions filter(in(names), pkgs) else pkgs end
    isempty(present) || runpkg(:remove, present, present, member)
    allversions && spread!(:remove, globaldir, pkgs)
    notifyenvchange()
end

remove(pkgs::AbstractString...; kwargs...) = remove(collect(String, pkgs); kwargs...)

"""
    update(pkgs::Vector{String} = String[]; allversions = false)
    update(pkgs::AbstractString...; allversions = false)

Update the packages named `pkgs` of the global environment and its
autoloads member, or all of their packages when `pkgs` is empty, in one
resolve of the shared manifest. With `allversions`, every other Julia
version with an autoloads environment does the same when it next starts a
REPL session.

# Raises
- `ErrorException` before `init` has run, or when Pkg fails.

# Example
```julia
Autoloads.update()
```
"""
function update(pkgs::Vector{String} = String[]; allversions::Bool = false)
    globaldir = globalenvdir()
    existingmember(globaldir)
    runpkg(:update, pkgs, pkgs, globaldir)
    if allversions
        for member in versionmembers(globaldir)
            member.dir == memberdir(globaldir) || defer!(member.version, "update", pkgs)
        end
    end
    notifyenvchange()
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
extension renders the report.

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
function status(io::IO = stdout, pkgs::AbstractString...)
    autoloads = readautoloads(globalenvdir(), catalogpath())
    Base.require(PKG_ID)
    Base.invokelatest(printstatus, io, autoloads, pkgs...)
end

status(pkg::AbstractString, pkgs::AbstractString...) = status(stdout, pkg, pkgs...)

"""
    printstatus(io, autoloads, pkgs...)

Print the `status` report of `autoloads`, as `readautoloads` gives it. Its
methods are in the Pkg extension.
"""
function printstatus end

# Other Julia versions

function previousmember(globaldir::AbstractString)
    older = filter(member -> member.version.major == VERSION.major && member.version.minor < VERSION.minor,
                   versionmembers(globaldir))
    isempty(older) && return nothing
    (; version, dir) = argmax(member -> member.version, older)
    names = sort!([id.name for id in projectdeps(joinpath(dir, "Project.toml"))])
    if !isempty(names); (; minor = Int(version.minor), dir, names) end
end

function versionmembers(globaldir::AbstractString)
    parent = dirname(globaldir)
    members = @NamedTuple{version::VersionNumber, dir::String}[]
    isdir(parent) || return members
    for name in readdir(parent)
        version = tryparse(VersionNumber, name)
        dir = joinpath(parent, name, "autoloads")
        version !== nothing && name == "v$(version.major).$(version.minor)" && isfile(joinpath(dir, "Project.toml")) &&
            push!(members, (; version, dir))
    end
    members
end

function spread!(op::Symbol, globaldir::AbstractString, names::Vector{String})
    source = memberdir(globaldir)
    targets = [member for member in versionmembers(globaldir) if member.dir != source]
    isempty(targets) && return
    projecttext(member) = read(joinpath(member.dir, "Project.toml"), String)
    before = map(projecttext, targets)
    try
        runpkgscript(op, names, `$(joinpath(SCRIPTS_DIR, "spread.jl")) $op $source $(join(names, ',')) \
                                       $([member.dir for member in targets])`; project = source)
    finally
        for (member, text) in zip(targets, before)
            projecttext(member) == text || defer!(member.version, "resolve")
        end
    end
end

"""
    defer!(version::VersionNumber, op::AbstractString, pkgs::Vector{String} = String[])

Queue `op` (`resolve`, or `update` of `pkgs`, all if none) for Julia `version`.
"""
function defer!(version::VersionNumber, op::AbstractString, pkgs::Vector{String} = String[])
    path = joinpath(statedir(version), DEFERRED_FILE)
    withfilelock(() -> open(io -> println(io, join([op; pkgs], ' ')), path, "a"), path)
end

"""
    applydeferred!(globaldir::AbstractString; output::IO = stdout) -> Bool

Apply the changes other Julia versions deferred to this one, in one resolve or
update. Returns whether there were any; on failure they stay queued.
"""
function applydeferred!(globaldir::AbstractString; output::IO = stdout)
    path = joinpath(statedir(), DEFERRED_FILE)
    isfile(path) || return false
    content = withfilelock(() -> read(path, String), path)
    requests = split.(split(content, '\n'; keepempty = false))
    updates = [String.(request[2:end]) for request in requests if first(request) == "update"]
    if isempty(updates)
        runpkg(:resolve, String[], String[], globaldir; output)
    else
        pkgs = if any(isempty, updates) String[] else unique!(reduce(vcat, updates)) end
        runpkg(:update, pkgs, pkgs, globaldir; output)
    end
    dropapplied!(path, content)
    notifyenvchange()
    true
end

"""
    dropapplied!(path::AbstractString, applied::AbstractString)

Remove `applied` from the start of the deferred file at `path`, keeping lines appended since.
"""
function dropapplied!(path::AbstractString, applied::AbstractString)
    withfilelock(path) do
        isfile(path) || return
        rest = chopprefix(read(path, String), applied)
        if isempty(rest) rm(path) else write(path, rest) end
    end
end

function adoptprevious!(globaldir::AbstractString; output::IO = stdout)
    previous = previousmember(globaldir)
    previous === nothing || createenvironment(globaldir, previous.dir; output)
    previous
end

# Utility functions

function createenvironment(globaldir::AbstractString, source::AbstractString; output::IO = stdout)
    runpkgscript(:init, String[], `$(joinpath(SCRIPTS_DIR, "init.jl")) $globaldir $source`;
                       project = globaldir, output)
    autoloadsuuid = Base.PkgId(@__MODULE__).uuid
    any(id -> id.uuid == autoloadsuuid, projectdeps(joinpath(globaldir, "Project.toml"))) ||
        @warn "The global environment ($globaldir) does not depend on Autoloads, so `using Autoloads` \
               will not find it there; run `pkg> add Autoloads` with the global environment active"
    notifyenvchange()
end

function askcarryover(previous)
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

function existingmember(globaldir::AbstractString)
    member = memberdir(globaldir)
    isfile(joinpath(member, "Project.toml")) ||
        error("There is no autoloads environment at $member; create it with `pkg> autoloads init` ",
              "(or `Autoloads.init()`), then try again.")
    member
end

runpkg(op::Symbol, pkgs::Vector{String}, args::Vector{String}, project::AbstractString; output::IO = stdout) =
    runpkgscript(op, pkgs, `$(joinpath(SCRIPTS_DIR, "pkg.jl")) $op $args`; project, output)

function runpkgscript(op::Symbol, pkgs::Vector{String}, args::Cmd; project::AbstractString, output::IO = stdout)
    process = runjulia(args; project, env = PKG_SUBPROCESS_ENV, output)
    wait(process)
    @debug "Autoloads Pkg subprocess exited" op pkgs project process.exitcode
    success(process) ||
        error("Autoloads.$op failed", if isempty(pkgs) "" else " for $(join(pkgs, ", "))" end, " in $project: ",
              "its Pkg subprocess exited with code $(process.exitcode). The Pkg output above gives the reason; ",
              "fix that and try again.")
    nothing
end

function readautoloads(globaldir::AbstractString, catalog::AbstractString)
    cfg = loadconfig()
    member = memberdir(globaldir)
    memberenv = environment(joinpath(member, "Project.toml"))
    active = Base.active_project()
    projectenv = environment(active)
    builtins = builtinrecords()
    cat = buildcatalog([builtins; readcatalog(catalog)])
    autoload = autoloadset(memberenv.deps, memberenv.graph, projectenv.deps, projectenv.graph,
                            stdlibids(), [record.id for record in builtins], cfg)
    (; cfg, member, memberenv, active, projectenv, cat, autoload, registry = buildregistry(cat, autoload, cfg))
end
