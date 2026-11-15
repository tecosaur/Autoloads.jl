"""
The `pkg> autoloads` command group: `init`, `add`, `rm|remove`, `up|update`
and `st|status`, each calling the Autoloads function of the same name.
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

function __init__()
    specs = Dict{String, REPLMode.CommandSpec}()
    for spec in COMMANDS
        specs[spec.canonical_name] = spec
        spec.short_name === nothing || (specs[spec.short_name] = spec)
    end
    REPLMode.SPECS["autoloads"] = specs
    copy!(REPLMode.help.content, REPLMode.gen_help().content)
end

end
