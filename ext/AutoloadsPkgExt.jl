# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# The `pkg> autoloads` commands, refreshes after environment-changing `pkg>`
# commands, and the status report. Each part using Pkg's private `REPLMode` is
# skipped, with a warning, if its layout is unexpected.
module AutoloadsPkgExt

using Autoloads, Pkg, StyledStrings
using Autoloads: PkgFailure, ManifestGraph, ConfigError, Session, namesat, failedat, autoloadnames, packageconfig,
    owner

# The face of each kind of name (`Autoloads.NAME_KINDS`, and `@` for macros), in the order About.jl lists them.
const KIND_FACES = ['.' => :bright_red, '@' => :julia_macro, '+' => :julia_funcall, ':' => :julia_type,
                    '=' => :julia_identifier]

# `nothing` without a REPL mode; then every use below fails soft.
const REPLMode = if isdefined(Pkg, :REPLMode) Pkg.REPLMode end

function completeautoloads(_...; kwargs...)
    session = try
        Autoloads.readsession(Autoloads.globalenvdir(), Autoloads.catalogpath())
    catch err
        err isa ConfigError || rethrow()
        return String[]
    end
    sort!([id.name for id in keys(session.autoload)])
end

# Built when precompiling, against the Pkg it is loaded with (a different Pkg
# recompiles this extension), so building costs no load time; a failure is
# kept as its message for `registercommands!` to report.
# `init` and `status` are called splatted: as `init()` and `status(pkgs...)`.
const GLOBAL_OPTION = [Pair{Symbol, Any}[:name => "global", :short_name => "g", :api => :allversions => true]]
const COMMANDS = try
    REPLMode === nothing && error("this Pkg has no REPLMode")
    let command = (; help, kwargs...) -> REPLMode.CommandSpec(; help = REPLMode.Markdown.parse(help), kwargs...)
        [
        command(name = "init", api = Autoloads.init, arg_count = 0 => 0,
                description = "set up the global autoloads environment",
                help = """
                    autoloads init

                Set up the global autoloads environment, the `autoloads` workspace member of the
                global environment, and resolve it. When it is created, the autoload packages of
                the newest older Julia version's global environment can be carried over.
                """),
        command(name = "add", api = Autoloads.add, should_splat = false, arg_count = 1 => Inf,
                option_spec = GLOBAL_OPTION, completions = :complete_add_dev, description = "add packages to autoload",
                help = """
                    autoloads add [-g|--global] pkg ...

                Add packages to the global autoloads environment, by name, git URL (`url#rev` for a
                revision), or (for an existing directory) by path, which is developed. The
                environment is created first (as by `autoloads init`) if it does not exist yet.
                With `-g`, also add them to every other Julia version's autoloads environment.
                """),
        command(name = "remove", short_name = "rm", api = Autoloads.remove, should_splat = false,
                arg_count = 1 => Inf, option_spec = GLOBAL_OPTION, completions = :complete_installed_packages,
                description = "remove packages from the autoloads",
                help = """
                    autoloads [rm|remove] [-g|--global] pkg ...

                Remove packages from the global autoloads environment. With `-g`, also remove them
                from every other Julia version's autoloads environment.
                """),
        command(name = "update", short_name = "up", api = Autoloads.update, should_splat = false,
                arg_count = 0 => Inf, option_spec = GLOBAL_OPTION, completions = :complete_installed_packages,
                description = "update the global and autoload packages",
                help = """
                    autoloads [up|update] [-g|--global] [pkg ...]

                Update the given packages, or every package of the global environment and its
                autoloads, in one resolve, as `up` does with the global environment active. With
                `-g`, every other Julia version's autoloads environment is updated too.
                """),
        command(name = "status", short_name = "st", api = Autoloads.status, arg_count = 0 => Inf,
                completions = completeautoloads,
                description = "show what autoloads",
                help = """
                    autoloads [st|status] [pkg ...]

                Show the global and project autoload packages with their versions and what each
                offers (its exports, which autoload, and public names), the names more than one
                of them provides, and the precompile policy. Given autoload packages, show the
                names each offers and which of them autoload it.
                """),
        ]
    end
catch err
    sprint(showerror, err)
end

# `pkg>` commands after which the active environments may provide different names.
const ENV_CHANGING_COMMANDS = ["add", "rm", "up", "develop", "free", "pin", "resolve", "instantiate"]

const COMMAND_SPEC_FIELDS = (:canonical_name, :short_name, :api, :should_splat, :argument_spec,
                             :option_specs, :completions, :description, :help)

struct RefreshingApi{F <: Function} <: Function
    api::F
end

function (refreshing::RefreshingApi)(args...; kwargs...)
    result = refreshing.api(args...; kwargs...)
    Autoloads.notifyenvchange()
    result
end

"""
    wrappkgcommands!()

Make the `ENV_CHANGING_COMMANDS` request an autoload refresh, and `up` in the
global environment also update the autoload packages unless `uphook` is off.
Idempotent; warns and changes nothing if Pkg's layout is unexpected.
"""
function wrappkgcommands!()
    specs = if isdefined(REPLMode, :SPECS) && isdefined(REPLMode, :CommandSpec) get(REPLMode.SPECS, "package", nothing) end
    if !(specs isa Dict{String, REPLMode.CommandSpec}) || fieldnames(REPLMode.CommandSpec) != COMMAND_SPEC_FIELDS ||
       !all(name -> haskey(specs, name), ENV_CHANGING_COMMANDS)
        @warn "Autoloads cannot refresh after `pkg>` commands: this Pkg's REPLMode.SPECS/CommandSpec layout is not recognised" version = Pkg.pkgversion(Pkg)
        return
    end
    up = specs["up"]
    function withautoloads()
        Base.active_project() == joinpath(Autoloads.globalenvdir(), "Project.toml") || return false
        try
            Autoloads.loadconfig().uphook
        catch err
            err isa ConfigError || rethrow()
            @warn "The Autoloads settings are invalid, so `up` leaves the autoload packages alone" exception = err
            false
        end
    end
    for original in unique(objectid, specs[name] for name in ENV_CHANGING_COMMANDS)
        original.api isa RefreshingApi && continue
        api = RefreshingApi(if original === up
                                (args...; kwargs...) -> original.api(args...; workspace = withautoloads(), kwargs...)
                            else original.api end)
        wrapped = REPLMode.CommandSpec((if f === :api api else getfield(original, f) end for f in COMMAND_SPEC_FIELDS)...)
        for (name, spec) in specs
            spec === original && (specs[name] = wrapped)
        end
    end
end

function Autoloads.printstatus(@nospecialize(io::IO), session::Session)
    (; config, member, memberenv, active, projectenv, registry) = session
    print(io, styled"{bold:Global autoloads}  {shadow:$(Base.contractuser(member))}")
    isfile(joinpath(member, "Project.toml")) ||
        print(io, styled"  {warning:(missing; create it with `pkg> autoloads init`)}")
    println(io)
    printpackages(io, session, memberenv.deps, memberenv.graph)
    println(io, styled"\n{bold:Project autoloads}  {shadow:$(Base.contractuser(something(active, \"\")))}")
    (; project) = config
    selected = [id for id in projectenv.deps if project === nothing || id.name in project]
    printpackages(io, session, selected, projectenv.graph)
    for (title, note, claims) in (("Shared names", "autoloaded once one of their packages is loaded", registry.shared),
                                  ("Ambiguous names", "not autoloaded", registry.ambiguous))
        isempty(claims) && continue
        println(io, styled"\n{bold:$title}  {shadow:($note)}")
        claimed = Dict{String, Vector{String}}()
        for (name, ids) in claims
            push!(get!(claimed, join(sort!([id.name for id in ids]), ", "), String[]), String(name))
        end
        for (claimants, names) in sort!(collect(claimed); by = first)
            println(io, "  ", claimants, styled" {shadow:($(length(names)))}")
            printwrapped(io, sort!(names; by = lowercase))
        end
    end
    println(io, styled"\n{bold:Precompile policy}  $(lowercase(string(config.policy)))")
end

function Autoloads.printstatus(@nospecialize(io::IO), session::Session, pkgs::AbstractString...)
    ids = Dict(id.name => id for id in keys(session.autoload))
    for pkg in pkgs
        haskey(ids, pkg) || throw(ArgumentError("Autoloads.status: $pkg is not an autoload package here. \
            `pkg> autoloads st` lists them; `pkg> autoloads add $pkg` adds it."))
    end
    for (i, pkg) in enumerate(pkgs)
        i == 1 || println(io)
        printpackage(io, session, ids[pkg])
    end
end

function printpackage(@nospecialize(io::IO), session::Session, id::Base.PkgId)
    (; config, catalog, autoload, registry) = session
    version = autoload[id]
    glyph, state = indexcells(indexstate(session, id, version), (0, 0))
    println(io, glyph, styled" {bold:$(id.name)}", if version === nothing "" else styled" {shadow:v$version}" end, "  ", state)
    record = namesat(catalog, id, version)
    record === nothing && return
    kind(name) = if startswith(String(name), '@') '@' else get(record.kinds, name, '?') end
    rank(name) = something(findfirst(==(kind(name)) ∘ first, KIND_FACES), length(KIND_FACES) + 1)
    bykind(names) = sort!(collect(names); by = name -> (rank(name), lowercase(String(name))))
    function shown(name)
        face = last(get(KIND_FACES, rank(name), '?' => :default))
        styled"{code,$face:$name}"
    end
    offered = bykind(autoloadnames(record, packageconfig(config, id.name)))
    function printnames(title, note, names)
        isempty(names) && return
        println(io, styled"\n  {bold:$title} ($(length(names)))", if isempty(note) "" else styled"  {shadow:$note}" end)
        printwrapped(io, names)
    end
    function printclaimed(title, note, claims)
        others(name) = join(sort!([other.name for other in claims[name] if other != id]), ", ")
        printnames(title, note, [shown(name) * styled" {shadow:($(others(name)))}" for name in offered if haskey(claims, name)])
    end
    printnames("Autoloads", "", [shown(name) for name in offered if owner(registry, name) == id])
    printclaimed("Shared", "autoloaded once one of their packages is loaded", registry.shared)
    printclaimed("Ambiguous", "not autoloaded", registry.ambiguous)
    printnames("Re-exported", "loads the owner",
                [shown(name) * styled" {shadow:($(owner(registry, name).name))}" for name in offered
                 if owner(registry, name) ∉ (id, nothing)])
    printnames("Excluded", "by the settings", map(shown, bykind(setdiff(record.exported ∪ record.reexported, offered))))
    printnames("Public", "not autoloaded", map(shown, bykind(record.public)))
end

function printpackages(@nospecialize(io::IO), session::Session, ids::Vector{Base.PkgId}, graph::ManifestGraph)
    isempty(ids) && return println(io, styled"  {shadow:(none)}")
    rows = map(sort(ids; by = id -> id.name)) do id
        version = get(graph.versions, id.uuid, nothing)
        (id.name, if version === nothing "" else "v$version" end, indexstate(session, id, version))
    end
    namewidth, versionwidth = maximum(textwidth ∘ first, rows), maximum(row -> textwidth(row[2]), rows)
    counts = [state for (_, _, state) in rows if state isa NTuple{2, Int}]
    countwidths = (maximum(ndigits ∘ first, counts; init = 0), maximum(ndigits ∘ last, counts; init = 0))
    for (name, version, state) in rows
        glyph, description = indexcells(state, countwidths)
        println(io, "  ", glyph, " ", rpad(name, namewidth), "  ", styled"{shadow:$(rpad(version, versionwidth))}",
                "  ", description)
    end
end

function printwrapped(@nospecialize(io::IO), names::Vector{<:AbstractString})
    line = "   "
    for (i, name) in enumerate(names)
        entry = if i < length(names) name * "," else name end
        if i > 1 && textwidth(line) + 1 + textwidth(entry) > displaysize(io)[2]
            println(io, line)
            line = "   "
        end
        line *= " " * entry
    end
    println(io, line)
end

function indexstate((; catalog, config)::Session, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    record = namesat(catalog, id, version)
    record === nothing && return failedat(catalog, id, version)
    (length(autoloadnames(record, packageconfig(config, id.name))), length(record.public))
end

indexcells(::Nothing, widths) = styled"{warning:○}", styled"{warning:not indexed}"
indexcells(failure::PkgFailure, widths) =
    styled"{error:✗}", styled"{error:failed:} $(first(split(failure.message, '\n')))"

function indexcells((exports, public)::NTuple{2, Int}, (exportswidth, publicwidth))
    noun = if exports == 1 "export" else "exports" end
    counts = styled"{blue:$(lpad(exports, exportswidth))} "
    styled"{success:✓}", if public == 0 counts * noun else
        counts * rpad(noun * ",", length("exports, ")) * styled"{magenta:$(lpad(public, publicwidth))} public"
    end
end

function __init__()
    registercommands!()
    wrappkgcommands!()
end

function registercommands!()
    try
        COMMANDS isa String && error(COMMANDS)
        specs = Dict{String, REPLMode.CommandSpec}()
        for spec in COMMANDS
            specs[spec.canonical_name] = spec
            spec.short_name === nothing || (specs[spec.short_name] = spec)
        end
        REPLMode.SPECS["autoloads"] = specs
        copy!(REPLMode.help.content, REPLMode.gen_help().content)
    catch err
        @warn "Autoloads cannot add the `pkg> autoloads` commands to this Pkg's REPL; call `Autoloads.add` and \
               the other management functions instead" version = Pkg.pkgversion(Pkg) exception = err
    end
    nothing
end

# Precompile workload: an empty global environment, but the user's settings and active project.
if ccall(:jl_generating_output, Cint, ()) == 1
    try
        session = Autoloads.readsession(mktempdir(), joinpath(mktempdir(), "catalog"))
        Autoloads.printstatus(devnull, session)
        foreach(id -> Autoloads.printstatus(devnull, session, id.name), first(keys(session.autoload), 1))
        completeautoloads(nothing, "", 1, 1)
    catch err
        err isa ConfigError || rethrow()
    end
end

end
