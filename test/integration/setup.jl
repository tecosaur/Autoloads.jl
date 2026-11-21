# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Shared integration-test workspace: a temporary depot whose global
# environment has the `autoloads` member, with the fixtures developed into it.
# Included (not auto-run) by the integration test files.

# Keeps the default catalog, here and in subprocesses, out of the user's state directory.
ENV["XDG_STATE_HOME"] = mktempdir()

const PATH_SEPARATOR = if Sys.iswindows() ';' else ':' end

const FIXTURES_DIR = joinpath(dirname(@__DIR__), "fixtures")
const FIXTURE_A = Base.PkgId(Base.UUID("a0a0a0a0-1111-4111-8111-00000000000a"), "FixtureA")
const FIXTURE_B = Base.PkgId(Base.UUID("b0b0b0b0-2222-4222-8222-00000000000b"), "FixtureB")
const FIXTURE_C = Base.PkgId(Base.UUID("c0c0c0c0-3333-4333-8333-00000000000c"), "FixtureC")

"""
    buildworkspace(; fixtures = (FIXTURE_A, FIXTURE_B, FIXTURE_C)) -> NamedTuple

Build a temporary depot holding a global environment (`[workspace] projects =
["autoloads"]`) whose `autoloads` member has the `fixtures` `Pkg.develop`ed
(path dependencies, offline). Returns `(; depot, depotpath,
globalenv, member)`: `depotpath` is the `JULIA_DEPOT_PATH` for subprocesses,
the temporary depot first, then the current depots, so installed packages and
registries resolve while new caches land in the temporary depot. Removed when
the test process exits.

Raises `ErrorException` with the Pkg output if developing the fixtures fails.
"""
function buildworkspace(; fixtures = (FIXTURE_A, FIXTURE_B, FIXTURE_C))
    depot = mktempdir()
    depotpath = join([depot; DEPOT_PATH], PATH_SEPARATOR)
    globalenv = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)")
    member = joinpath(globalenv, "autoloads")
    mkpath(member)
    write(joinpath(globalenv, "Project.toml"), "[workspace]\nprojects = [\"autoloads\"]\n")
    write(joinpath(member, "Project.toml"), "")
    # Pkg runs in a subprocess so this session's environment stays untouched.
    script = "using Pkg; Pkg.develop([PackageSpec(path = p) for p in ARGS])"
    paths = [joinpath(FIXTURES_DIR, id.name) for id in fixtures]
    output = IOBuffer()
    process = runjulia(`-e $script $paths`; project = member, output,
                        env = ("JULIA_DEPOT_PATH" => depotpath, "JULIA_PKG_OFFLINE" => "true",
                               "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
    wait(process)
    success(process) ||
        error("Developing the fixtures into $member failed (exit code $(process.exitcode)):\n",
              String(take!(output)))
    (; depot, depotpath, globalenv, member)
end

"Start Julia on `args`, printing to `output`, in `project` or else the default environment."
function runjulia(args::Cmd; project = nothing, output::IO, env = ())
    projectflag = if project === nothing; `` else `--project=$project` end
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --history-file=no $projectflag $args`, env...)
    run(pipeline(cmd; stdout = output, stderr = output); wait = false)
end
