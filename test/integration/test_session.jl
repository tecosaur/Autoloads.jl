# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestSession

using Test, REPL, Future, Autoloads
using Autoloads: PkgNames, CatalogRecord, stdlibids, writecatalog!

include("setup.jl")

"Sightings of `version` on this Julia minor."
here(version) = Autoloads.Sighting[(; version, julia = Autoloads.JULIA_MINOR)]

const CASES = joinpath(@__DIR__, "session_cases.jl")
const TEST_PROJECT = dirname(@__DIR__)
const AUTOLOADS_UUID = Base.PkgId(Autoloads).uuid
# The member group develops FixtureB into its member, so it gets a workspace of its own.
const SHARED = buildworkspace(; fixtures = (FIXTURE_A,))
const CHANGING = buildworkspace(; fixtures = (FIXTURE_A,))
# SHARED's depots behind one whose global environment has no member, so its caches are reused.
const NO_MEMBER = let depot = mktempdir()
    globalenv = mkpath(joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)"))
    write(joinpath(globalenv, "Project.toml"), "")
    (; depotpath = join([depot, SHARED.depotpath], PATH_SEPARATOR))
end
# Stdlibs whose real names a test relies on (`@spawn`, `status`), or that
# every catalog write loads (FileWatching).
const REAL_STDLIBS = ("Distributed", "Pkg", "FileWatching", "Statistics")

"""
The namespaces of the `REAL_STDLIBS`, extracted in a subprocess whose depot
path starts with the workspace's, so no cache lands in the user's depot.
"""
function realstdlibrecords(ws)
    script = """
        push!(LOAD_PATH, ARGS[1])
        using Autoloads
        for id in Autoloads.stdlibids()
            id.name in ARGS[2:end] && println(Autoloads.catalogline(Autoloads.extractnames(Base.require(id), id)))
        end
        """
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => ws.depotpath, "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing) do
        runjulia(`-e $script $TEST_PROJECT $REAL_STDLIBS`; project = nothing, output)
    end
    wait(process)
    text = String(take!(output))
    success(process) || error("Extracting the names of $(join(REAL_STDLIBS, ", ")) failed:\n", text)
    CatalogRecord[Autoloads.parsecatalogline(line) for line in split(text, '\n'; keepempty = false)]
end

"A record offering only the stdlib's own name, at its version, without loading it."
function stdlibstub(id::Base.PkgId)
    version = get(Base.parsed_toml(joinpath(Sys.STDLIB, id.name, "Project.toml")), "version", nothing)
    PkgNames(id, here(if version !== nothing VersionNumber(version) end), Set([Symbol(id.name)]),
             Set{Symbol}(), Set{Symbol}())
end

# Seeded records are never re-indexed, so sessions start without indexing them.
const STDLIB_RECORDS = CatalogRecord[realstdlibrecords(SHARED);
                                     [stdlibstub(id) for id in stdlibids() if id.name ∉ REAL_STDLIBS]]
const FIXTURE_A_NAMES = PkgNames(FIXTURE_A, here(v"0.1.0"), Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST]),
                                 Set([:fa_public]), Set{Symbol}())
# FixtureB re-exports `fa`; FixtureC owns a `fa` of its own.
const FIXTURE_B_NAMES = PkgNames(FIXTURE_B, here(v"0.1.0"), Set([:FixtureB, :fb]), Set{Symbol}(), Set([:fa]))
const FIXTURE_C_NAMES = PkgNames(FIXTURE_C, here(v"0.1.0"), Set([:FixtureC, :fa]), Set{Symbol}(), Set{Symbol}())
const STRANGER_NAMES = PkgNames(Base.PkgId(Base.UUID("5555aaaa-1111-4111-8111-000000000005"), "Stranger"), here(v"1.0.0"),
                                Set([:Stranger, :stranger_fn]), Set{Symbol}(), Set{Symbol}())
const FIXTURE_UUIDS = Dict(id.name => id.uuid for id in (FIXTURE_A, FIXTURE_B, FIXTURE_C))

catalogin(state) = withenv(Autoloads.catalogpath, "XDG_STATE_HOME" => state)

"A fresh state directory whose catalog holds the stdlib records and `extra`."
function seededstate(extra::CatalogRecord...)
    state = mktempdir()
    writecatalog!(catalogin(state), CatalogRecord[STDLIB_RECORDS; extra...])
    state
end

"""
A project depending on the fixtures named in `deps` (path dependencies, with a
manifest covering every fixture), with `prefs` as its `[preferences.Autoloads]`.
"""
function fixtureproject(deps; prefs = "")
    dir = mktempdir()
    deplines = join(("$name = \"$(FIXTURE_UUIDS[name])\"\n" for name in deps))
    write(joinpath(dir, "Project.toml"), """
          [deps]
          $deplines
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

"Start the `session_cases.jl` subprocess for `group` in `ws`'s depots and `state`; returns it and its output buffer."
function startcases(group, ws, state, extra...; project = nothing)
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => ws.depotpath, "XDG_STATE_HOME" => state, "JULIA_LOAD_PATH" => nothing,
                      "JULIA_PROJECT" => nothing) do
        runjulia(`$CASES $group $TEST_PROJECT $extra`; project, output)
    end
    (; group, process, output)
end

function checkcases((; group, process, output))
    wait(process)
    success(process) || println("session case group $group failed:\n", String(take!(output)))
    @test success(process)
end

"Whether loading Autoloads into a fresh non-interactive process loads nothing else."
function loadsonlyautoloads()
    script = """
        before = collect(keys(Base.loaded_modules))
        push!(LOAD_PATH, ARGS[1])
        using Autoloads
        print(collect(setdiff(keys(Base.loaded_modules), before)) == [Base.PkgId(Autoloads)])
        """
    output = IOBuffer()
    process = withenv("JULIA_DEPOT_PATH" => SHARED.depotpath, "JULIA_LOAD_PATH" => nothing,
                      "JULIA_PROJECT" => nothing) do
        runjulia(`-e $script $TEST_PROJECT`; project = nothing, output)
    end
    wait(process)
    String(take!(output)) == "true"
end

@testset "session" begin
    witha = seededstate(FIXTURE_A_NAMES)
    projectstate = seededstate(FIXTURE_A_NAMES)
    projects = (; selecting = fixtureproject(["FixtureA", "FixtureB"]; prefs = "project = [\"FixtureA\"]"),
                unselected = fixtureproject(["FixtureA"]; prefs = "project = false"),
                without = fixtureproject(String[]; prefs = "project = [\"FixtureA\"]"))
    stdlibproject = fixtureproject(String[]; prefs = """
        stdlib = true
        packages.Distributed.skip = ["@spawn"]
        """)
    brokenproject = fixtureproject(String[]; prefs = "stdlib = \"yes\"")
    hintstate = seededstate(FIXTURE_A_NAMES, FIXTURE_B_NAMES, FIXTURE_C_NAMES)
    bareproject = fixtureproject(String[])
    rm(joinpath(bareproject, "Manifest.toml"))
    onlyb = fixtureproject(["FixtureB"]; prefs = "project = [\"FixtureB\"]")
    runs = [startcases("member", CHANGING, seededstate()),
            startcases("sequencing", SHARED, witha),
            startcases("macro", SHARED, seededstate(FIXTURE_A_NAMES)),
            startcases("stdlib", SHARED, seededstate(FIXTURE_A_NAMES), brokenproject; project = stdlibproject),
            startcases("project", NO_MEMBER, projectstate, projects.unselected, projects.without,
                        projects.selecting; project = projects.selecting)]
    push!(runs, startcases("hints", SHARED, hintstate, bareproject; project = onlyb),
          startcases("hints-bare", NO_MEMBER, seededstate(FIXTURE_B_NAMES, STRANGER_NAMES); project = onlyb))
    unwritable = seededstate(FIXTURE_A_NAMES)
    chmod(dirname(catalogin(unwritable)), 0o555)
    push!(runs, startcases("unwritable", SHARED, unwritable))
    @testset "using Autoloads loads nothing else" begin
        @test loadsonlyautoloads()
    end
    foreach(checkcases, runs)
    chmod(dirname(catalogin(unwritable)), 0o755)
    @testset "an unchanged observation writes nothing" begin
        checkcases(startcases("observe-again", NO_MEMBER, projectstate; project = projects.selecting))
    end
end

@testset "a catalog in a newer format turns autoloading off, with one warning" begin
    Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
    catalog = joinpath(mktempdir(), "catalog")
    content = "Autoloads catalog v$(Autoloads.CATALOG_FORMAT + 1)\n"
    write(catalog, content)
    worker = Ext.Worker(Ext.Runtime(Channel{Ext.Event}(Inf), SHARED.member, catalog), Ext.Indexer())
    logger = Test.TestLogger(; respect_maxlog = true)
    sessions = Base.CoreLogging.with_logger(() -> [Ext.derivesession(worker) for _ in 1:2], logger)
    @test sessions == [(nothing, nothing), (nothing, nothing)]
    @test count(log -> log.level == Base.CoreLogging.Warn && log.message == "Autoloads is off", logger.logs) == 1
    @test !Ext.observe!(worker, [Base.PkgId(Autoloads)])
    @test read(catalog, String) == content
end

end
