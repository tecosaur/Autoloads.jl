# A module keeps these helpers apart from the other test files' globals.
module TestSession

using Test, REPL, Autoloads
using Autoloads: PkgNames, CatalogRecord, extract_names, stdlib_ids, write_catalog_changes!, run_julia

include("setup.jl")

const CASES = joinpath(@__DIR__, "session_cases.jl")
const TEST_PROJECT = dirname(@__DIR__)
const AUTOLOADS_UUID = Base.PkgId(Autoloads).uuid
# The member group develops FixtureB into its member, so it gets a workspace of its own.
const SHARED = build_workspace(; fixtures = (FIXTURE_A,))
const CHANGING = build_workspace(; fixtures = (FIXTURE_A,))
# Seeded records are never re-indexed, so sessions start without indexing them.
const STDLIB_RECORDS = CatalogRecord[extract_names(Base.require(id), id) for id in stdlib_ids()]
const FIXTURE_A_NAMES = PkgNames(FIXTURE_A, [v"0.1.0"], Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST]),
                                 Set([:fa_public]), Set{Symbol}())
const FIXTURE_UUIDS = Dict(id.name => id.uuid for id in (FIXTURE_A, FIXTURE_B, FIXTURE_C))

"A fresh catalog holding the stdlib records and `extra`."
function seeded_catalog(extra::CatalogRecord...)
    path = joinpath(mktempdir(), "catalog-v1")
    write_catalog_changes!(path, CatalogRecord[STDLIB_RECORDS; extra...])
    path
end

"""
A project depending on the fixtures named in `deps` (path dependencies, with a
manifest covering every fixture), with `prefs` as its `[preferences.Autoloads]`.
"""
function fixture_project(deps; prefs = "")
    dir = mktempdir()
    dep_lines = join(("$name = \"$(FIXTURE_UUIDS[name])\"\n" for name in deps))
    write(joinpath(dir, "Project.toml"), """
          [deps]
          $dep_lines
          [extras]
          Autoloads = "$AUTOLOADS_UUID"

          [preferences.Autoloads]
          $prefs
          """)
    entry(name, extra = "") = """
        [[deps.$name]]
        $(extra)path = "$(escape_string(joinpath(FIXTURES_DIR, name)))"
        uuid = "$(FIXTURE_UUIDS[name])"
        version = "0.1.0"
        """
    write(joinpath(dir, "Manifest.toml"), join(["manifest_format = \"2.0\"\n",
        entry("FixtureA"), entry("FixtureB", "deps = [\"FixtureA\"]\n"), entry("FixtureC")], '\n'))
    dir
end

"Start the `session_cases.jl` subprocess for `group`; returns it and its output buffer."
function start_cases(group, ws, member, catalog, extra...; project = nothing)
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => ws.depot_path, "JULIA_LOAD_PATH" => nothing,
                      "JULIA_PROJECT" => nothing) do
        run_julia(`$CASES $group $TEST_PROJECT $member $catalog $extra`; project, output)
    end
    (; group, process, output)
end

function check_cases((; group, process, output))
    wait(process)
    success(process) || println("session case group $group failed:\n", String(take!(output)))
    @test success(process)
end

"Whether loading Autoloads into a fresh non-interactive process loads nothing else."
function loads_only_autoloads()
    script = """
        before = collect(keys(Base.loaded_modules))
        push!(LOAD_PATH, ARGS[1])
        using Autoloads
        print(collect(setdiff(keys(Base.loaded_modules), before)) == [Base.PkgId(Autoloads)])
        """
    output = IOBuffer()
    wait(run_julia(`-e $script $TEST_PROJECT`; project = nothing, output))
    String(take!(output)) == "true"
end

@testset "session" begin
    with_a = seeded_catalog(FIXTURE_A_NAMES)
    project_catalog = seeded_catalog(FIXTURE_A_NAMES)
    projects = (; selecting = fixture_project(["FixtureA", "FixtureB"]; prefs = "project = [\"FixtureA\"]"),
                unselected = fixture_project(["FixtureA"]),
                without = fixture_project(String[]; prefs = "project = [\"FixtureA\"]"))
    stdlib_project = fixture_project(String[]; prefs = """
        stdlib = true
        packages.Distributed.skip = ["@spawn"]
        """)
    broken_project = fixture_project(String[]; prefs = "stdlib = \"yes\"")
    no_member = joinpath(mktempdir(), "autoloads")
    runs = [start_cases("member", CHANGING, CHANGING.member, seeded_catalog()),
            start_cases("sequencing", SHARED, SHARED.member, with_a),
            start_cases("macro", SHARED, SHARED.member, seeded_catalog(FIXTURE_A_NAMES)),
            start_cases("stdlib", SHARED, SHARED.member, seeded_catalog(FIXTURE_A_NAMES), broken_project;
                        project = stdlib_project),
            start_cases("project", SHARED, no_member, project_catalog, projects.unselected, projects.without,
                        projects.selecting; project = projects.selecting)]
    @testset "using Autoloads loads nothing else" begin
        @test loads_only_autoloads()
    end
    foreach(check_cases, runs)
    @testset "an unchanged observation writes nothing" begin
        check_cases(start_cases("observe-again", SHARED, no_member, project_catalog; project = projects.selecting))
    end
end

end
