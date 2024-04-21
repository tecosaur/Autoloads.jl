module PkgExt

using Autoloads

using Pkg
import Pkg.REPLMode.CommandSpec
import Pkg.REPLMode.Markdown: @md_str

const complete_pkg = @static if VERSION >= v"1.11-alpha1"
    Pkg.REPLMode.get_complete_function(:complete_add_dev)
else
    Pkg.REPLMode.complete_add_dev
end

const complete_installed_pkg = @static if VERSION >= v"1.11-alpha1"
    Pkg.REPLMode.get_complete_function(:complete_installed_packages)
else
    Pkg.REPLMode.complete_installed_packages
end

const add_spec = CommandSpec(
    name = "add",
    api = add_autoload,
    help = md"
    add [-s|--soft] [-h|--hard] pkgs...

Add a new package to the autoloads.",
    description = "Add autoloaded packages",
    option_spec = Vector{Pair{Symbol, Any}}[
        [:name => "soft", :short_name => "s", :api => :level => :soft],
        [:name => "hard", :short_name => "h", :api => :level => :hard],
    ],
    arg_count = 0 => Inf,
    should_splat = false,
    completions = complete_pkg
)

const remove_spec = CommandSpec(
    name = "remove",
    api = remove_autoload,
    help = md"
    [remove|rm] pkgs...

Remove package(s) from the autoloads.",
    description = "Remove autoloaded packages",
    arg_count = 0 => Inf,
    should_splat = false,
    completions = complete_installed_pkg
)

const status_spec = CommandSpec(
    name = "status",
    api = remove_autoload,
    help = md"
    [status|st]

Show the current autoload setup.",
    description = "Show the current autoload setup",
    should_splat = false
)

const update_spec = CommandSpec(
    name = "update",
    api = remove_autoload,
    arg_parser = Pkg.REPLMode.parse_package,
    arg_count = 0 => Inf,
    help = md"
    [update|up]

Show the current autoload setup.",
    description = "Show the current autoload setup",
    should_splat = false,
    completions = complete_installed_pkg
)

const CMD_SPECS = [
    "add" => add_spec,
    "rm" => remove_spec,
    "remove" => remove_spec,
    "st" => status_spec,
    "status" => status_spec,
    "up" => update_spec,
    "update" => update_spec,
]

function __init__()
    Pkg.REPLMode.SPECS["autoloads"] = CMD_SPECS
    # update the help with the new commands
    copy!(Pkg.REPLMode.help.content, Pkg.REPLMode.gen_help().content)
end

end
