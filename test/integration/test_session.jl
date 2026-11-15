# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestSession

using Test, REPL, Autoloads
using Autoloads: PkgNames, CatalogRecord, stdlib_ids, write_catalog_changes!, run_julia

include("setup.jl")

const CASES = joinpath(@__DIR__, "session_cases.jl")
const TEST_PROJECT = dirname(@__DIR__)
const AUTOLOADS_UUID = Base.PkgId(Autoloads).uuid
# The member group develops FixtureB into its member, so it gets a workspace of its own.
const SHARED = build_workspace(; fixtures = (FIXTURE_A,))
const CHANGING = build_workspace(; fixtures = (FIXTURE_A,))
# Stdlibs whose real names a test relies on (`@spawn`, `status`), or that
# every catalog write loads (FileWatching).
const REAL_STDLIBS = ("Distributed", "Pkg", "FileWatching", "Statistics")

"""
The namespaces of the `REAL_STDLIBS`, extracted in a subprocess whose depot
path starts with the workspace's, so no cache lands in the user's depot.
"""
function real_stdlib_records(ws)
    script = """
        push!(LOAD_PATH, ARGS[1])
        using Autoloads
        for id in Autoloads.stdlib_ids()
            id.name in ARGS[2:end] && println(Autoloads.catalog_line(Autoloads.extract_names(Base.require(id), id)))
        end
        """
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => ws.depot_path, "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing) do
        run_julia(`-e $script $TEST_PROJECT $REAL_STDLIBS`; project = nothing, output)
    end
    wait(process)
    text = String(take!(output))
    success(process) || error("Extracting the names of $(join(REAL_STDLIBS, ", ")) failed:\n", text)
    CatalogRecord[Autoloads.parse_catalog_line(line) for line in split(text, '\n'; keepempty = false)]
end

"A record offering only the stdlib's own name, at its version, without loading it."
function stdlib_stub(id::Base.PkgId)
    version = get(Base.parsed_toml(joinpath(Sys.STDLIB, id.name, "Project.toml")), "version", nothing)
    PkgNames(id, version === nothing ? VersionNumber[] : [VersionNumber(version)], Set([Symbol(id.name)]),
             Set{Symbol}(), Set{Symbol}())
end

# Seeded records are never re-indexed, so sessions start without indexing them.
const STDLIB_RECORDS = CatalogRecord[real_stdlib_records(SHARED);
                                     [stdlib_stub(id) for id in stdlib_ids() if id.name ∉ REAL_STDLIBS]]
const FIXTURE_A_NAMES = PkgNames(FIXTURE_A, [v"0.1.0"], Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST]),
                                 Set([:fa_public]), Set{Symbol}())
# FixtureB re-exports `fa`; FixtureC owns a `fa` of its own.
const FIXTURE_B_NAMES = PkgNames(FIXTURE_B, [v"0.1.0"], Set([:FixtureB, :fb]), Set{Symbol}(), Set([:fa]))
const FIXTURE_C_NAMES = PkgNames(FIXTURE_C, [v"0.1.0"], Set([:FixtureC, :fa]), Set{Symbol}(), Set{Symbol}())
const STRANGER_NAMES = PkgNames(Base.PkgId(Base.UUID("5555aaaa-1111-4111-8111-000000000005"), "Stranger"), [v"1.0.0"],
                                Set([:Stranger, :stranger_fn]), Set{Symbol}(), Set{Symbol}())
const FIXTURE_UUIDS = Dict(id.name => id.uuid for id in (FIXTURE_A, FIXTURE_B, FIXTURE_C))

"A fresh catalog holding the stdlib records and `extra`."
function seeded_catalog(extra::CatalogRecord...)
    path = joinpath(mktempdir(), "catalog")
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
    process = withenv("JULIA_DEPOT_PATH" => SHARED.depot_path, "JULIA_LOAD_PATH" => nothing,
                      "JULIA_PROJECT" => nothing) do
        run_julia(`-e $script $TEST_PROJECT`; project = nothing, output)
    end
    wait(process)
    String(take!(output)) == "true"
end

@testset "session" begin
    with_a = seeded_catalog(FIXTURE_A_NAMES)
    project_catalog = seeded_catalog(FIXTURE_A_NAMES)
    projects = (; selecting = fixture_project(["FixtureA", "FixtureB"]; prefs = "project = [\"FixtureA\"]"),
                unselected = fixture_project(["FixtureA"]; prefs = "project = false"),
                without = fixture_project(String[]; prefs = "project = [\"FixtureA\"]"))
    stdlib_project = fixture_project(String[]; prefs = """
        stdlib = true
        packages.Distributed.skip = ["@spawn"]
        """)
    broken_project = fixture_project(String[]; prefs = "stdlib = \"yes\"")
    no_member = joinpath(mktempdir(), "autoloads")
    hint_catalog = seeded_catalog(FIXTURE_A_NAMES, FIXTURE_B_NAMES, FIXTURE_C_NAMES)
    bare_project = fixture_project(String[])
    rm(joinpath(bare_project, "Manifest.toml"))
    only_b = fixture_project(["FixtureB"]; prefs = "project = [\"FixtureB\"]")
    runs = [start_cases("member", CHANGING, CHANGING.member, seeded_catalog()),
            start_cases("sequencing", SHARED, SHARED.member, with_a),
            start_cases("macro", SHARED, SHARED.member, seeded_catalog(FIXTURE_A_NAMES)),
            start_cases("stdlib", SHARED, SHARED.member, seeded_catalog(FIXTURE_A_NAMES), broken_project;
                        project = stdlib_project),
            start_cases("project", SHARED, no_member, project_catalog, projects.unselected, projects.without,
                        projects.selecting; project = projects.selecting)]
    push!(runs, start_cases("hints", SHARED, SHARED.member, hint_catalog, bare_project; project = only_b),
          start_cases("hints-bare", SHARED, no_member, seeded_catalog(FIXTURE_B_NAMES, STRANGER_NAMES);
                      project = only_b))
    unwritable = seeded_catalog(FIXTURE_A_NAMES)
    chmod(dirname(unwritable), 0o555)
    push!(runs, start_cases("unwritable", SHARED, SHARED.member, unwritable))
    @testset "using Autoloads loads nothing else" begin
        @test loads_only_autoloads()
    end
    foreach(check_cases, runs)
    chmod(dirname(unwritable), 0o755)
    @testset "an unchanged observation writes nothing" begin
        check_cases(start_cases("observe-again", SHARED, no_member, project_catalog; project = projects.selecting))
    end
end

end
