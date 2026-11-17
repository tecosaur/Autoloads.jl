# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
The `pkg> autoloads` command group: `init`, `add`, `rm|remove`, `up|update`
and `st|status`, each calling the Autoloads function of the same name; and
the wrapping of the environment-changing `pkg>` commands so they request an
autoload refresh. Both use Pkg's private `REPLMode`, so they are confined to
[`COMMANDS`](@ref), [`register_commands!`](@ref) and
[`wrap_pkg_commands!`](@ref), and each is skipped with a warning if Pkg's
layout is not as expected. Also renders `Autoloads.status` (`print_status`).
"""
module AutoloadsPkgExt

using Autoloads, Pkg, StyledStrings
using Autoloads: PkgFailure, ManifestGraph, ConfigError, names_at, failed_at, autoload_names,
    package_config, owner, ambiguities

# The face of each kind of name (`Autoloads.NAME_KINDS`, and `@` for macros), in the order About.jl lists them.
const KIND_FACES = ['.' => :bright_red, '@' => :julia_macro, '+' => :julia_funcall, ':' => :julia_type,
                    '=' => :julia_identifier]

# `nothing` without a REPL mode; then every use below fails soft.
const REPLMode = if isdefined(Pkg, :REPLMode) Pkg.REPLMode end

# Built when precompiling, against the Pkg it is loaded with (a different Pkg
# recompiles this extension), so building costs no load time; a failure is
# kept as its message for `register_commands!` to report.
# `init` and `status` are called splatted: as `init()` and `status(pkgs...)`.
# Other Julia versions' changes are resolved when each next starts a session.

"Completions for a package argument of `autoloads status`: the autoload packages; none while the settings are invalid."
function complete_autoload_packages(options, partial, offset, index; kwargs...)
    autoloads = try
        Autoloads.read_autoloads(Autoloads.global_env_dir(), Autoloads.catalog_path())
    catch err
        err isa ConfigError || rethrow()
        return String[]
    end
    sort!([id.name for id in keys(autoloads.autoload)])
end

const GLOBAL_OPTION = [Pair{Symbol, Any}[:name => "global", :short_name => "g", :api => :all_versions => true]]
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
                autoloads, in one resolve. With `-g`, every other Julia version's autoloads
                environment is updated too.
                """),
        command(name = "status", short_name = "st", api = Autoloads.status, arg_count = 0 => Inf,
                completions = complete_autoload_packages,
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

"A Pkg command `api` that calls `api`, then requests an autoload refresh."
struct RefreshingApi{F <: Function} <: Function
    api::F
end

function (refreshing::RefreshingApi)(args...; kwargs...)
    result = refreshing.api(args...; kwargs...)
    Autoloads.notify_env_change()
    result
end

"""
    wrap_pkg_commands!()

Make each of [`ENV_CHANGING_COMMANDS`](@ref) call `Autoloads.notify_env_change()` after
its `api` succeeds, under every alias. Idempotent; commands already wrapped by this
function, and other wrappers on any command, are left to coexist. Warns and changes
nothing if Pkg's `CommandSpec` or `SPECS` are not as expected.
"""
function wrap_pkg_commands!()
    specs = find_package_specs()
    if specs === nothing
        @warn "Autoloads cannot refresh after `pkg>` commands: this Pkg's REPLMode.SPECS/CommandSpec layout is not recognised" pkg_version = Pkg.pkgversion(Pkg)
        return
    end
    for original in unique(objectid, specs[name] for name in ENV_CHANGING_COMMANDS)
        original.api isa RefreshingApi && continue
        wrapped = REPLMode.CommandSpec((if f === :api RefreshingApi(original.api) else getfield(original, f) end
                                        for f in COMMAND_SPEC_FIELDS)...)
        for (name, spec) in specs
            spec === original && (specs[name] = wrapped)
        end
    end
end

"Pkg's `package` command table, or `nothing` if Pkg's layout lacks it or any command we wrap."
function find_package_specs()
    isdefined(REPLMode, :SPECS) && isdefined(REPLMode, :CommandSpec) || return nothing
    specs = get(REPLMode.SPECS, "package", nothing)
    specs isa Dict{String, REPLMode.CommandSpec} || return nothing
    fieldnames(REPLMode.CommandSpec) == COMMAND_SPEC_FIELDS || return nothing
    if all(name -> haskey(specs, name), ENV_CHANGING_COMMANDS) specs end
end

function Autoloads.print_status(@nospecialize(io::IO), autoloads::NamedTuple)
    (; cfg, member, member_env, active, project_env, registry) = autoloads
    print(io, styled"{bold:Global autoloads}  {shadow:$(Base.contractuser(member))}")
    isfile(joinpath(member, "Project.toml")) ||
        print(io, styled"  {warning:(missing; create it with `pkg> autoloads init`)}")
    println(io)
    print_packages(io, autoloads, member_env.deps, member_env.graph)
    println(io, styled"\n{bold:Project autoloads}  {shadow:$(Base.contractuser(something(active, \"\")))}")
    print_packages(io, autoloads, [id for id in project_env.deps if cfg.project === nothing || id.name in cfg.project],
                   project_env.graph)
    claimed = Dict{String, Vector{String}}()
    for (name, ids) in ambiguities(registry)
        push!(get!(claimed, join(sort!([id.name for id in ids]), ", "), String[]), String(name))
    end
    note = if isempty(claimed) "none" else "(not autoloaded)" end
    println(io, styled"\n{bold:Ambiguous names}  {shadow:$note}")
    for (claimants, names) in sort!(collect(claimed); by = first)
        println(io, "  ", claimants, styled" {shadow:($(length(names)))}")
        print_wrapped(io, sort!(names; by = lowercase))
    end
    println(io, styled"\n{bold:Precompile policy}  $(lowercase(string(cfg.policy)))")
end

function Autoloads.print_status(@nospecialize(io::IO), autoloads::NamedTuple, pkgs::AbstractString...)
    (; cfg, cat, autoload, registry) = autoloads
    ids = Dict(id.name => id for id in keys(autoload))
    for pkg in pkgs
        haskey(ids, pkg) || throw(ArgumentError("Autoloads.status: $pkg is not an autoload package here. \
            `pkg> autoloads st` lists them; `pkg> autoloads add $pkg` adds it."))
    end
    for (i, id) in enumerate(ids[pkg] for pkg in pkgs)
        version = autoload[id]
        glyph, state = index_cells(index_state(autoloads, id, version), (0, 0))
        i == 1 || println(io)
        println(io, glyph, styled" {bold:$(id.name)}", if version === nothing "" else styled" {shadow:v$version}" end, "  ", state)
        record = names_at(cat, id, version)
        record === nothing && continue
        rank(name) = findfirst(==(if startswith(String(name), '@') '@' else get(record.kinds, name, '?') end) ∘ first, KIND_FACES)
        function shown(name)
            face = last(get(KIND_FACES, something(rank(name), 0), '?' => :default))
            styled"{code,$face:$name}"
        end
        by_kind(names) = sort!(collect(names); by = name -> (something(rank(name), typemax(Int)), lowercase(String(name))))
        function print_names(title, note, names)
            isempty(names) && return
            println(io, styled"\n  {bold:$title} ($(length(names)))", if isempty(note) "" else styled"  {shadow:$note}" end)
            print_wrapped(io, names)
        end
        offered = by_kind(autoload_names(record, package_config(cfg, id.name)))
        print_names("Autoloads", "", [shown(name) for name in offered if owner(registry, name) == id])
        contested = ambiguities(registry)
        others(name) = join(sort!([other.name for other in contested[name] if other != id]), ", ")
        print_names("Ambiguous", "not autoloaded",
                    [shown(name) * styled" {shadow:($(others(name)))}" for name in offered if haskey(contested, name)])
        print_names("Re-exported", "loads the owner",
                    [shown(name) * styled" {shadow:($(owner(registry, name).name))}" for name in offered
                     if !haskey(contested, name) && owner(registry, name) != id])
        print_names("Excluded", "by the settings", map(shown, by_kind(setdiff(record.exported ∪ record.reexported, offered))))
        print_names("Public", "not autoloaded", map(shown, by_kind(record.public)))
    end
end

function print_packages(@nospecialize(io::IO), autoloads::NamedTuple, ids::Vector{Base.PkgId}, graph::ManifestGraph)
    isempty(ids) && return println(io, styled"  {shadow:(none)}")
    rows = map(sort(ids; by = id -> id.name)) do id
        version = get(graph.versions, id.uuid, nothing)
        (id.name, if version === nothing "" else "v$version" end, index_state(autoloads, id, version))
    end
    name_width, version_width = maximum(textwidth ∘ first, rows), maximum(row -> textwidth(row[2]), rows)
    counts = [state for (_, _, state) in rows if state isa NTuple{2, Int}]
    count_widths = (maximum(ndigits ∘ first, counts; init = 0), maximum(ndigits ∘ last, counts; init = 0))
    for (name, version, state) in rows
        glyph, description = index_cells(state, count_widths)
        println(io, "  ", glyph, " ", rpad(name, name_width), "  ", styled"{shadow:$(rpad(version, version_width))}",
                "  ", description)
    end
end

"Print `names` comma-separated at an indent of four, wrapped to the width of `io`."
function print_wrapped(@nospecialize(io::IO), names::Vector{<:AbstractString})
    line = "   "
    for (i, name) in enumerate(names)
        entry = if i < length(names) name * "," else name end
        if textwidth(line) + 1 + textwidth(entry) > displaysize(io)[2] && line != "   "
            println(io, line)
            line = "   "
        end
        line *= " " * entry
    end
    println(io, line)
end

"How `id` at `version` is indexed: its `(exports, public)` name counts, its `PkgFailure`, or `nothing` if it is not."
function index_state((; cat, cfg)::NamedTuple, id::Base.PkgId, version::Union{VersionNumber, Nothing})
    record = names_at(cat, id, version)
    record === nothing && return failed_at(cat, id, version)
    (length(autoload_names(record, package_config(cfg, id.name))), length(record.public))
end

# The glyph and description of an `index_state`; `widths` align the counts of a table's rows.
index_cells(::Nothing, widths) = styled"{warning:○}", styled"{warning:not indexed}"
index_cells(failure::PkgFailure, widths) =
    styled"{error:✗}", styled"{error:failed:} $(first(split(failure.message, '\n')))"

function index_cells((exports, public)::NTuple{2, Int}, (exports_width, public_width))
    noun = if exports == 1 "export" else "exports" end
    counts = styled"{blue:$(lpad(exports, exports_width))} $noun"
    styled"{success:✓}", if public == 0 counts else
        counts * rpad(",", 9 - length(noun)) * styled"{magenta:$(lpad(public, public_width))} public"
    end
end

function __init__()
    register_commands!()
    wrap_pkg_commands!()
end

"""
    register_commands!()

Add the `pkg> autoloads` command group of [`COMMANDS`](@ref) to Pkg's
`REPLMode.SPECS` and regenerate the `pkg>` help. Warns instead of throwing
if Pkg's layout is not as expected.
"""
function register_commands!()
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
               the other management functions instead" pkg_version = Pkg.pkgversion(Pkg) exception = err
    end
    nothing
end

# Precompile workload: an empty global environment, but the user's settings and active project.
if ccall(:jl_generating_output, Cint, ()) == 1
    try
        autoloads = Autoloads.read_autoloads(mktempdir(), joinpath(mktempdir(), "catalog"))
        Autoloads.print_status(devnull, autoloads)
        foreach(id -> Autoloads.print_status(devnull, autoloads, id.name), first(keys(autoloads.autoload), 1))
        complete_autoload_packages(nothing, "", 1, 1)
    catch err
        err isa ConfigError || rethrow()
    end
end

end
