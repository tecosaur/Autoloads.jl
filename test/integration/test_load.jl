# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestLoad

using Test, REPL, Autoloads

include("setup.jl")

const WS = build_workspace()
const CASES = joinpath(@__DIR__, "load_cases.jl")
const TEST_PROJECT = dirname(@__DIR__)

"A project outside the workspace with a FixtureA copy at v0.2.0 as a path dependency."
function conflicting_project()
    dir = mktempdir()
    mkpath(joinpath(dir, "FixtureA"))
    cp(joinpath(FIXTURES_DIR, "FixtureA", "src"), joinpath(dir, "FixtureA", "src"))
    write(joinpath(dir, "FixtureA", "Project.toml"),
          "name = \"FixtureA\"\nuuid = \"$(FIXTURE_A.uuid)\"\nversion = \"0.2.0\"\n")
    write(joinpath(dir, "Project.toml"), "[deps]\nFixtureA = \"$(FIXTURE_A.uuid)\"\n")
    write(joinpath(dir, "Manifest.toml"), """
          manifest_format = "2.0"

          [[deps.FixtureA]]
          path = "FixtureA"
          uuid = "$(FIXTURE_A.uuid)"
          version = "0.2.0"
          """)
    dir
end

"Start the `load_cases.jl` subprocess for `group`; returns it and its output buffer."
function start_cases(group; project = nothing)
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => WS.depot_path, "JULIA_LOAD_PATH" => nothing,
                      "JULIA_PROJECT" => nothing) do
        run_julia(`$CASES $group $TEST_PROJECT $(WS.member)`; project, output)
    end
    (; group, process, output)
end

@testset "member_only_roots" begin
    member_only_roots = Base.get_extension(Autoloads, :AutoloadsREPLExt).member_only_roots
    stmt = :(@time begin
        using Base.Threads, Main.X, Test, .Relative
        using Core: Box
        using NotHere.Sub: y
        import NotHereEither as Z
    end)
    @test member_only_roots(stmt) == [:NotHere, :NotHereEither]
    @test isempty(member_only_roots(:(x = 1)))
end

@testset "load" begin
    runs = [start_cases("global"), start_cases("used"), start_cases("project"; project = conflicting_project())]
    for (; group, process, output) in runs
        wait(process)
        success(process) || println("load case group $group failed:\n", String(take!(output)))
        @test success(process)
    end
end

end
