"""
The `pkg> autoloads` command group: `init`, `add`, `rm|remove`, `up|update`
and `st|status`, each calling the Autoloads function of the same name; and
the wrapping of the environment-changing `pkg>` commands so they request an
autoload refresh. The wrapping edits Pkg's private `REPLMode.SPECS`, so it is
confined to [`wrap_pkg_commands!`](@ref) and skipped with a warning if Pkg's
layout is not as expected.
"""
module AutoloadsPkgExt

using Autoloads, Pkg

const REPLMode = Pkg.REPLMode

command(; help, kwargs...) = REPLMode.CommandSpec(; help = REPLMode.Markdown.parse(help), kwargs...)

# `init` and `status` take no arguments, so are called splatted: as `init()`.
const COMMANDS = [
    command(name = "init", api = Autoloads.init, arg_count = 0 => 0,
            description = "set up the global autoloads environment",
            help = """
                autoloads init

            Set up the global autoloads environment, the `autoloads` workspace member of the
            global environment, and resolve it. When it is created, the autoload packages of
            the newest older Julia version's global environment can be carried over.
            """),
    command(name = "add", api = Autoloads.add, should_splat = false, arg_count = 1 => Inf,
            completions = :complete_add_dev, description = "add packages to autoload",
            help = """
                autoloads add pkg ...

            Add packages to the global autoloads environment, by name or (for an existing
            directory) by path, which is developed.
            """),
    command(name = "remove", short_name = "rm", api = Autoloads.remove, should_splat = false,
            arg_count = 1 => Inf, completions = :complete_installed_packages,
            description = "remove packages from the autoloads",
            help = """
                autoloads [rm|remove] pkg ...

            Remove packages from the global autoloads environment.
            """),
    command(name = "update", short_name = "up", api = Autoloads.update, should_splat = false,
            arg_count = 0 => Inf, completions = :complete_installed_packages,
            description = "update the global and autoload packages",
            help = """
                autoloads [up|update] [pkg ...]

            Update the given packages, or every package of the global environment and its
            autoloads, in one resolve.
            """),
    command(name = "status", short_name = "st", api = Autoloads.status, arg_count = 0 => 0,
            description = "show what autoloads",
            help = """
                autoloads [st|status]

            Show the global and project autoload packages with their versions and indexing
            state, the names more than one of them provides, the precompile policy, and the
            global autoloads environment's path.
            """),
]

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
        wrapped = REPLMode.CommandSpec((f === :api ? RefreshingApi(original.api) : getfield(original, f)
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
    all(name -> haskey(specs, name), ENV_CHANGING_COMMANDS) ? specs : nothing
end

function __init__()
    specs = Dict{String, REPLMode.CommandSpec}()
    for spec in COMMANDS
        specs[spec.canonical_name] = spec
        spec.short_name === nothing || (specs[spec.short_name] = spec)
    end
    REPLMode.SPECS["autoloads"] = specs
    wrap_pkg_commands!()
    copy!(REPLMode.help.content, REPLMode.gen_help().content)
end

end
