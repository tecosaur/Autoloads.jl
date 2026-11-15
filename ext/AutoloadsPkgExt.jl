# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
The `pkg> autoloads` command group: `init`, `add`, `rm|remove`, `up|update`
and `st|status`, each calling the Autoloads function of the same name; and
the wrapping of the environment-changing `pkg>` commands so they request an
autoload refresh. Both use Pkg's private `REPLMode`, so they are confined to
[`COMMANDS`](@ref), [`register_commands!`](@ref) and
[`wrap_pkg_commands!`](@ref), and each is skipped with a warning if Pkg's
layout is not as expected.
"""
module AutoloadsPkgExt

using Autoloads, Pkg

# `nothing` without a REPL mode; then every use below fails soft.
const REPLMode = isdefined(Pkg, :REPLMode) ? Pkg.REPLMode : nothing

# Built when precompiling, against the Pkg it is loaded with (a different Pkg
# recompiles this extension), so building costs no load time; a failure is
# kept as its message for `register_commands!` to report.
# `init` and `status` take no arguments, so are called splatted: as `init()`.
# Other Julia versions' changes are resolved when each next starts a session.
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
        command(name = "status", short_name = "st", api = Autoloads.status, arg_count = 0 => 0,
                description = "show what autoloads",
                help = """
                    autoloads [st|status]

                Show the global and project autoload packages with their versions and indexing
                state, the names more than one of them provides, the precompile policy, and the
                global autoloads environment's path.
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

end
