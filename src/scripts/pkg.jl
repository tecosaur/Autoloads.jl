# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Pkg operations on the global autoloads environment, run by `Autoloads.add`,
# `remove` and `update` as
#
#     julia --project=<env> pkg.jl <add|remove|update> <package>...
#
# `add` develops the paths of existing directories and adds the rest from
# their git URL (`url#rev` for a revision) or by name; `update` updates every package of the workspace when given none. A
# Pkg or resolver error is printed without a backtrace and exits 1.

const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))

function main(op, pkgs)
    # A git URL (`url#rev` picks a revision), or else a registered name.
    function package_spec(pkg)
        is_url = occursin("://", pkg) || startswith(pkg, "git@") || endswith(pkg, ".git")
        is_url || return Pkg.PackageSpec(name = pkg)
        url, rev = if occursin('#', pkg) String.(split(pkg, '#'; limit = 2)) else (pkg, nothing) end
        Pkg.PackageSpec(; url, rev)
    end
    if op == "add"
        paths = filter(isdir, pkgs)
        isempty(paths) || Pkg.develop([Pkg.PackageSpec(path = path) for path in paths])
        specs = [package_spec(pkg) for pkg in pkgs if !isdir(pkg)]
        isempty(specs) || Pkg.add(specs)
    elseif op == "remove"
        Pkg.rm(pkgs)
    elseif op == "update"
        isempty(pkgs) ? Pkg.update(; workspace = true) : Pkg.update(pkgs; workspace = true)
    else
        error("pkg.jl: unknown operation `$op`; expected add, remove or update")
    end
end

try
    main(ARGS[1], ARGS[2:end])
catch err
    err isa Union{Pkg.Types.PkgError, Pkg.Resolve.ResolverError} || rethrow()
    printstyled(stderr, "ERROR: "; bold = true, color = :red)
    println(stderr, err.msg)
    exit(1)
end
