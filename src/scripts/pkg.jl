# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Run by `Autoloads.add`, `remove` and `update` as
#
#     julia --project=<env> pkg.jl <add|remove|update|resolve> <package>...
#
# For `add`, each package is an absolute path to develop, a git URL, or a name.

const Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))

function main(op, pkgs)
    # A git URL (`url#rev` picks a revision), or else a registered name.
    function packagespec(pkg)
        occursin("://", pkg) || startswith(pkg, "git@") || return Pkg.PackageSpec(name = pkg)
        url, rev = if occursin('#', pkg) String.(split(pkg, '#'; limit = 2)) else (pkg, nothing) end
        Pkg.PackageSpec(; url, rev)
    end
    if op == "add"
        paths = filter(isabspath, pkgs)
        isempty(paths) || Pkg.develop([Pkg.PackageSpec(path = path) for path in paths])
        specs = [packagespec(pkg) for pkg in pkgs if !isabspath(pkg)]
        isempty(specs) || Pkg.add(specs)
    elseif op == "remove"
        Pkg.rm(pkgs)
    elseif op == "update"
        if isempty(pkgs)
            Pkg.update(; workspace = true)
        else
            Pkg.update(pkgs; workspace = true)
        end
    elseif op == "resolve"
        Pkg.resolve()
    else
        error("pkg.jl: unknown operation `$op`; expected add, remove, update or resolve")
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
