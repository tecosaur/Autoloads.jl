# Shared integration-test workspace: a temporary depot whose global
# environment has the `autoloads` member, with the fixtures developed into it.
# Included (not auto-run) by the integration test files.

using Autoloads: run_julia

const FIXTURES_DIR = joinpath(dirname(@__DIR__), "fixtures")
const FIXTURE_A = Base.PkgId(Base.UUID("a0a0a0a0-1111-4111-8111-00000000000a"), "FixtureA")
const FIXTURE_B = Base.PkgId(Base.UUID("b0b0b0b0-2222-4222-8222-00000000000b"), "FixtureB")
const FIXTURE_C = Base.PkgId(Base.UUID("c0c0c0c0-3333-4333-8333-00000000000c"), "FixtureC")

"""
    build_workspace() -> NamedTuple

Build a temporary depot holding a global environment (`[workspace] projects =
["autoloads"]`) whose `autoloads` member has FixtureA, FixtureB and FixtureC
`Pkg.develop`ed (path dependencies, offline). Returns `(; depot, depot_path,
global_env, member)`: `depot_path` is the `JULIA_DEPOT_PATH` for subprocesses,
the temporary depot first, then the current depots, so installed packages and
registries resolve while new caches land in the temporary depot. Removed when
the test process exits.

Raises `ErrorException` with the Pkg output if developing the fixtures fails.
"""
function build_workspace()
    depot = mktempdir()
    depot_path = join([depot; DEPOT_PATH], Sys.iswindows() ? ';' : ':')
    global_env = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)")
    member = joinpath(global_env, "autoloads")
    mkpath(member)
    write(joinpath(global_env, "Project.toml"), "[workspace]\nprojects = [\"autoloads\"]\n")
    write(joinpath(member, "Project.toml"), "")
    # Pkg runs in a subprocess so this session's environment stays untouched.
    script = "using Pkg; Pkg.develop([PackageSpec(path = p) for p in ARGS])"
    paths = [joinpath(FIXTURES_DIR, id.name) for id in (FIXTURE_A, FIXTURE_B, FIXTURE_C)]
    output = IOBuffer()
    process = run_julia(`-e $script $paths`; project = member, output,
                        env = ("JULIA_DEPOT_PATH" => depot_path, "JULIA_PKG_OFFLINE" => "true",
                               "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
    wait(process)
    success(process) ||
        error("Developing the fixtures into $member failed (exit code $(process.exitcode)):\n",
              String(take!(output)))
    (; depot, depot_path, global_env, member)
end
