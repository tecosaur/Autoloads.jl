# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestManage

using Test, REPL, Future, Autoloads
using Autoloads: PkgNames, PkgFailure, readcatalog,
    writecatalog!, projectdeps

include("setup.jl")

"Sightings of `version` on this Julia minor."
here(version) = Autoloads.Sighting[(; version, julia = Autoloads.JULIA_MINOR)]

const AUTOLOADS_DIR = dirname(dirname(@__DIR__))
const AUTOLOADS_UUID = Base.PkgId(Autoloads).uuid
const ENV_NAME = "v$(VERSION.major).$(VERSION.minor)"
const PREVIOUS_ENV_NAME = "v$(VERSION.major).$(VERSION.minor - 1)"

stdlibuuid(name) = Base.parsed_toml(joinpath(Sys.STDLIB, name, "Project.toml"))["uuid"]

"A fresh depot with a global environment whose Project.toml is `project`; returns `(; depotpath, globaldir)`."
function freshglobalenv(project)
    depot = mktempdir()
    globaldir = joinpath(depot, "environments", ENV_NAME)
    mkpath(globaldir)
    write(joinpath(globaldir, "Project.toml"), project)
    (; depotpath = join([depot; DEPOT_PATH], Sys.iswindows() ? ';' : ':'), globaldir)
end

"Write an autoloads member for the sibling environment `name` of `globaldir`."
function siblingmember(globaldir, name, project)
    dir = joinpath(dirname(globaldir), name, "autoloads")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), project)
end

"Run `f()` with `depotpath` as the depot path, here and in subprocesses, and Pkg offline."
function indepot(f, depotpath)
    saved = copy(DEPOT_PATH)
    copy!(DEPOT_PATH, split(depotpath, Sys.iswindows() ? ';' : ':'))
    try
        withenv(f, "JULIA_DEPOT_PATH" => depotpath, "JULIA_PKG_OFFLINE" => "true",
                "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
    finally
        copy!(DEPOT_PATH, saved)
    end
end

"`indepot(f, depotpath)`, returning `f()` and everything printed to stdout."
function captured(f, depotpath)
    mktemp() do path, io
        value = indepot(() -> redirect_stdout(f, io), depotpath)
        flush(io)
        value, read(path, String)
    end
end

"A git repository, on branch `main`, holding a copy of fixture `name`."
function gitfixture(name)
    repo = mktempdir()
    cp(joinpath(FIXTURES_DIR, name), repo; force = true)
    git = `git -C $repo -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false`
    run(pipeline(`git init -q -b main $repo`; stdout = devnull))
    run(`$git add -A`)
    run(`$git commit -qm $name`)
    repo
end

membernames(member) = sort!([id.name for id in projectdeps(joinpath(member, "Project.toml"))])

@testset "init" begin
    @testset "creates the member, preserving the global project" begin
        env = freshglobalenv("""
            [deps]
            Printf = "$(stdlibuuid("Printf"))"

            [workspace]
            projects = ["x"]
            """)
        mkpath(joinpath(env.globaldir, "x"))
        write(joinpath(env.globaldir, "x", "Project.toml"), "")
        siblingmember(env.globaldir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlibuuid("Dates"))\"\n")
        projectfile = joinpath(env.globaldir, "Project.toml")
        notified = Ref(0)
        Autoloads.ENV_CHANGED[] = () -> notified[] += 1
        try
            _, output = captured(env.depotpath) do
                @test_logs (:warn, r"does not depend on Autoloads") Autoloads.init()
            end
            project = Base.parsed_toml(projectfile)
            @test project["deps"] == Dict("Printf" => stdlibuuid("Printf"))
            @test project["workspace"]["projects"] == ["x", "autoloads"]
            @test isfile(joinpath(env.globaldir, "autoloads", "Project.toml"))
            @test isfile(joinpath(env.globaldir, "Manifest.toml"))
            @test occursin("Created", output)
            @testset "a non-interactive :ask only says how to carry over" begin
                @test isempty(membernames(joinpath(env.globaldir, "autoloads")))
                @test occursin("autoloads add Dates", output)
            end
            @test notified[] == 1
            bytes = read(projectfile)
            _, output = captured(env.depotpath) do
                @test_logs (:warn, r"does not depend on Autoloads") Autoloads.init()
            end
            @test occursin("already", output) && !occursin("Created", output)
            @test read(projectfile) == bytes
            @test notified[] == 2
        finally
            Autoloads.ENV_CHANGED[] = nothing
        end
    end
    @testset "add creates a missing member first" begin
        env = freshglobalenv("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        _, output = captured(() -> Autoloads.add([joinpath(FIXTURES_DIR, "FixtureA")]), env.depotpath)
        @test occursin("Created", output)
        @test membernames(joinpath(env.globaldir, "autoloads")) == ["FixtureA"]
        @testset "and adds from a git URL" begin
            url = "file://" * gitfixture("FixtureC")
            captured(() -> Autoloads.add("$url#main"), env.depotpath)
            member = Base.parsed_toml(joinpath(env.globaldir, "autoloads", "Project.toml"))
            @test haskey(member["deps"], "FixtureC")
            @test VERSION < v"1.13-" || member["sources"]["FixtureC"] == Dict("url" => url, "rev" => "main")
        end
    end
    @testset "carries over the newest older member" begin
        env = freshglobalenv("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        previousroot = joinpath(dirname(env.globaldir), PREVIOUS_ENV_NAME)
        fixturea = joinpath(FIXTURES_DIR, "FixtureA")
        # FixtureA has a relative `[sources]` path; FixtureB's git source is in the manifest only.
        siblingmember(env.globaldir, PREVIOUS_ENV_NAME, """
            [deps]
            Dates = "$(stdlibuuid("Dates"))"
            FixtureA = "$(FIXTURE_A.uuid)"
            FixtureB = "$(FIXTURE_B.uuid)"

            [compat]
            Dates = "1"
            FixtureA = "0.1"
            julia = "1.10"

            [sources]
            FixtureA = {path = "$(escape_string(relpath(fixturea, joinpath(previousroot, "autoloads"))))"}
            """)
        repo = gitfixture("FixtureB")
        write(joinpath(previousroot, "Project.toml"),
              "[workspace]\nprojects = [\"autoloads\"]\n\n[preferences.Autoloads]\nlog = true\n")
        write(joinpath(previousroot, "LocalPreferences.toml"), "[Autoloads]\nstdlib = false\n")
        write(joinpath(previousroot, "Manifest.toml"), """
            manifest_format = "2.0"

            [[deps.Dates]]
            uuid = "$(stdlibuuid("Dates"))"

            [[deps.FixtureA]]
            path = "$(escape_string(fixturea))"
            uuid = "$(FIXTURE_A.uuid)"
            version = "0.1.0"

            [[deps.FixtureB]]
            deps = ["FixtureA"]
            repo-rev = "main"
            repo-url = "$(escape_string(repo))"
            uuid = "$(FIXTURE_B.uuid)"
            version = "0.1.0"
            """)
        siblingmember(env.globaldir, "v$(VERSION.major).$(VERSION.minor - 2)",
                       "[deps]\nPrintf = \"$(stdlibuuid("Printf"))\"\n")
        siblingmember(env.globaldir, "v$(VERSION.major).$(VERSION.minor + 1)",
                       "[deps]\nPrintf = \"$(stdlibuuid("Printf"))\"\n")
        _, output = captured(env.depotpath) do
            @test_logs Autoloads.init(; carryover = true)
        end
        member = Base.parsed_toml(joinpath(env.globaldir, "autoloads", "Project.toml"))
        @test member["deps"] == Dict("Dates" => stdlibuuid("Dates"), "FixtureA" => string(FIXTURE_A.uuid),
                                     "FixtureB" => string(FIXTURE_B.uuid))
        @test member["compat"] == Dict("Dates" => "1", "FixtureA" => "0.1", "julia" => "1.10")
        @test member["sources"] == Dict("FixtureA" => Dict("path" => fixturea),
                                        "FixtureB" => Dict("url" => repo, "rev" => "main"))
        @test occursin("carrying over 3 packages", output)
        globalproject = Base.parsed_toml(joinpath(env.globaldir, "Project.toml"))
        @test globalproject["workspace"]["projects"] == ["autoloads"]
        @testset "with the preferences" begin
            @test globalproject["preferences"]["Autoloads"] == Dict("log" => true)
            @test Base.parsed_toml(joinpath(env.globaldir, "LocalPreferences.toml")) ==
                Dict("Autoloads" => Dict("stdlib" => false))
        end
    end
    @testset "a failed resolve leaves the global environment as it was" begin
        env = freshglobalenv("[deps]\nPrintf = \"$(stdlibuuid("Printf"))\"\n")
        siblingmember(env.globaldir, PREVIOUS_ENV_NAME,
                       "[deps]\nNotRegistered = \"0d0d0d0d-4444-4444-8444-00000000000d\"\n")
        projectfile = joinpath(env.globaldir, "Project.toml")
        bytes = read(projectfile)
        err = try
            captured(() -> Autoloads.init(; carryover = true), env.depotpath)
            nothing
        catch err
            err
        end
        @test err isa ErrorException && startswith(err.msg, "Autoloads.init failed in $(env.globaldir):")
        @test read(projectfile) == bytes
        @test !ispath(joinpath(env.globaldir, "autoloads"))
        @test readdir(env.globaldir) == ["Project.toml"]
        @testset "and init can run again" begin
            captured(env.depotpath) do
                @test_logs (:warn,) Autoloads.init(; carryover = false)
            end
            @test isfile(joinpath(env.globaldir, "autoloads", "Project.toml"))
        end
    end
    @test_throws ArgumentError Autoloads.init(; carryover = :maybe)
end

@testset "add, remove, update and status" begin
    ws = buildworkspace(; fixtures = (FIXTURE_C,))
    ENV["XDG_STATE_HOME"] = mktempdir()
    catalog = Autoloads.catalogpath()
    statustext(pkgs...) = indepot(() -> sprint(io -> Autoloads.status(io, pkgs...)), ws.depotpath)
    fixturepath(id) = joinpath(FIXTURES_DIR, id.name)
    notified = Ref(0)
    Autoloads.ENV_CHANGED[] = () -> notified[] += 1
    try
        @testset "add" begin
            captured(() -> Autoloads.add([fixturepath(FIXTURE_A)]), ws.depotpath)
            @test membernames(ws.member) == ["FixtureA", "FixtureC"]
            @test notified[] == 1
            @test occursin(r"○ FixtureA +v0\.1\.0 +not indexed", statustext())
            writecatalog!(catalog, Autoloads.CatalogRecord[
                PkgNames(FIXTURE_A, here(v"0.1.0"), Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST]),
                         Set([:fa_public]), Set{Symbol}()),
                PkgFailure(FIXTURE_C, here(v"0.1.0"), "FixtureC failed to load\nStacktrace: ...")])
            text = statustext()
            @test occursin(r"✓ FixtureA +v0\.1\.0 +4 exports, 1 public\n", text)
            @test occursin(r"✗ FixtureC +v0\.1\.0 +failed: FixtureC failed to load\n", text)
        end
        @testset "re-adding a failed package clears its failure" begin
            captured(() -> Autoloads.add([fixturepath(FIXTURE_C)]), ws.depotpath)
            @test !any(r -> r isa PkgFailure, readcatalog(catalog))
            @test count(r -> r isa PkgNames, readcatalog(catalog)) == 1
            @test occursin(r"○ FixtureC +v0\.1\.0 +not indexed", statustext())
            @test notified[] == 2
        end
        @testset "status" begin
            writecatalog!(catalog, Autoloads.CatalogRecord[
                PkgNames(FIXTURE_C, here(v"0.1.0"), Set([:FixtureC, :fa]), Set{Symbol}(), Set{Symbol}())])
            text = statustext()
            @test startswith(text, "Global autoloads  $(Base.contractuser(ws.member))\n")
            @test occursin(r"✓ FixtureC +v0\.1\.0 +2 exports\n", text)
            @test occursin("\nProject autoloads", text)
            @test occursin("Ambiguous names  (not autoloaded)\n  FixtureA, FixtureC (1)\n    fa\n", text)
            @test endswith(text, "Precompile policy  background\n")
            styled = indepot(() -> sprint(Autoloads.status; context = :color => true), ws.depotpath)
            @test occursin("\e[1mGlobal autoloads\e[22m", styled) && occursin("\e[32m✓\e[39m", styled)
            @test occursin("\e[34m4\e[39m exports, \e[35m1\e[39m public", styled)
            @testset "of a package" begin
                text = statustext("FixtureA", "Statistics")
                @test startswith(text, "✓ FixtureA v0.1.0  4 exports, 1 public\n")
                @test occursin("  Autoloads (3)\n    @fam, FA_CONST, FixtureA\n", text)
                @test occursin("  Ambiguous (1)  not autoloaded\n    fa (FixtureC)\n", text)
                @test occursin("  Public (1)  not autoloaded\n    fa_public\n", text)
                @test occursin("\n\n○ Statistics", text) && endswith(text, "not indexed\n")
                narrow = indepot(() -> sprint(io -> Autoloads.status(IOContext(io, :displaysize => (24, 20)), "FixtureA")), ws.depotpath)
                @test occursin("    @fam, FA_CONST,\n    FixtureA\n", narrow)
                kinds = Dict(:FixtureA => '.', :fa => '+', :FA_CONST => '=')
                writecatalog!(catalog, Autoloads.CatalogRecord[
                    PkgNames(FIXTURE_A, here(v"0.1.0"), Set([keys(kinds)..., Symbol("@fam")]), Set([:fa_public]), Set{Symbol}(); kinds)])
                @test occursin("  Autoloads (3)\n    FixtureA, @fam, FA_CONST\n", statustext("FixtureA"))
                styled = indepot(() -> sprint(io -> Autoloads.status(io, "FixtureA"); context = :color => true), ws.depotpath)
                @test occursin(r"\e\[[0-9;]+mFixtureA\e\[[0-9;]+m, \e\[[0-9;]+m@fam", styled)
                origins = Dict(:shared_fn => Base.PkgId(Base.UUID(UInt128(1)), "Origin"))
                writecatalog!(catalog, Autoloads.CatalogRecord[
                    PkgNames(id, here(v"0.1.0"), Set([Symbol(id.name)]), Set{Symbol}(), Set([:shared_fn]); origins)
                    for id in (FIXTURE_A, FIXTURE_C)])
                @test occursin("Shared names  (autoloaded once one of their packages is loaded)\n  FixtureA, FixtureC (1)\n" *
                               "    shared_fn\n", statustext())
                @test occursin("  Shared (1)  autoloaded once one of their packages is loaded\n    shared_fn (FixtureC)\n",
                               statustext("FixtureA"))
                err = try statustext("FixtureA", "NotAPackage") catch err; err end
                @test err isa ArgumentError && occursin("autoloads add NotAPackage", sprint(showerror, err))
            end
            @testset "project autoloads" begin
                project = mktempdir()
                write(joinpath(project, "Project.toml"), """
                      [deps]
                      FixtureB = "$(FIXTURE_B.uuid)"

                      [extras]
                      Autoloads = "$AUTOLOADS_UUID"

                      [preferences.Autoloads]
                      project = true
                      """)
                before = Base.active_project()
                try
                    Base.set_active_project(joinpath(project, "Project.toml"))
                    @test occursin(r"Project autoloads.*\n  ○ FixtureB +not indexed\n", statustext())
                finally
                    Base.set_active_project(before)
                end
            end
        end
        @testset "update" begin
            captured(() -> Autoloads.update(), ws.depotpath)
            captured(() -> Autoloads.update(["FixtureC"]), ws.depotpath)
            @test membernames(ws.member) == ["FixtureA", "FixtureC"]
            @test notified[] == 4
        end
        @testset "remove" begin
            captured(() -> Autoloads.remove(["FixtureA"]), ws.depotpath)
            @test membernames(ws.member) == ["FixtureC"]
            @test !occursin("FixtureA", statustext())
            @test notified[] == 5
        end
        @testset "failures" begin
            err = try
                captured(() -> Autoloads.remove(["NotAPackage"]), ws.depotpath)
                nothing
            catch err
                err
            end
            @test err isa ErrorException && startswith(err.msg, "Autoloads.remove failed for NotAPackage in $(ws.member):")
            @test notified[] == 5
            @testset "a partly failed add still notifies" begin
                err = try
                    captured(() -> Autoloads.add([fixturepath(FIXTURE_A), "NotAPackage"]), ws.depotpath)
                    nothing
                catch err
                    err
                end
                @test err isa ErrorException && startswith(err.msg, "Autoloads.add failed")
                @test membernames(ws.member) == ["FixtureA", "FixtureC"]
                @test notified[] == 6
            end
            nomember = freshglobalenv("")
            @testset "names as separate arguments" begin
                @test_throws r"no autoloads environment.*autoloads init" indepot(() -> Autoloads.remove("FixtureA"), nomember.depotpath)
                @test_throws r"no autoloads environment.*autoloads init" indepot(() -> Autoloads.update("FixtureA"), nomember.depotpath)
                @test_throws ArgumentError Autoloads.add()
            end
        end
    finally
        Autoloads.ENV_CHANGED[] = nothing
    end
end

@testset "all Julia versions" begin
    ws = buildworkspace(; fixtures = (FIXTURE_C,))
    nextversion = VersionNumber(VERSION.major, VERSION.minor + 1)
    siblingmember(ws.globalenv, "v$(nextversion.major).$(nextversion.minor)",
                   "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
    sibling = joinpath(dirname(ws.globalenv), "v$(nextversion.major).$(nextversion.minor)", "autoloads")
    deferred(version) = (path = joinpath(Autoloads.statedir(version), Autoloads.DEFERRED_FILE);
                         isfile(path) ? readlines(path) : String[])
    fixturea = joinpath(FIXTURES_DIR, "FixtureA")
    try
        @testset "add and remove edit the other versions now, and defer their resolve" begin
            captured(() -> Autoloads.add([fixturea]; allversions = true), ws.depotpath)
            siblingproject = Base.parsed_toml(joinpath(sibling, "Project.toml"))
            @test membernames(sibling) == ["FixtureA", "FixtureC"]
            @test siblingproject["sources"]["FixtureA"] == Dict("path" => fixturea)
            @test deferred(nextversion) == ["resolve"]
            captured(() -> Autoloads.add([fixturea]; allversions = true), ws.depotpath)
            @test deferred(nextversion) == ["resolve"]  # unchanged, so nothing more to resolve
            captured(() -> Autoloads.remove(["FixtureA"]; allversions = true), ws.depotpath)
            @test membernames(ws.member) == membernames(sibling) == ["FixtureC"]
            @test !haskey(Base.parsed_toml(joinpath(sibling, "Project.toml")), "sources")
            @test deferred(nextversion) == ["resolve", "resolve"]
            @testset "a package only another version has" begin
                siblingmember(ws.globalenv, "v$(nextversion.major).$(nextversion.minor)",
                               "[deps]\nFixtureB = \"$(FIXTURE_B.uuid)\"\n")
                captured(() -> Autoloads.remove("FixtureB"; allversions = true), ws.depotpath)
                @test isempty(membernames(sibling)) && membernames(ws.member) == ["FixtureC"]
            end
        end
        @testset "update defers an update" begin
            captured(() -> Autoloads.update(["FixtureC"]; allversions = true), ws.depotpath)
            @test last(deferred(nextversion)) == "update FixtureC"
        end
        @testset "deferred changes apply once" begin
            Autoloads.defer!(VERSION, "resolve")
            Autoloads.defer!(VERSION, "update", ["FixtureC"])
            output = IOBuffer()
            @test withenv(() -> Autoloads.applydeferred!(ws.globalenv; output), "JULIA_DEPOT_PATH" => ws.depotpath,
                          "JULIA_PKG_OFFLINE" => "true")
            @test isempty(deferred(VERSION))
            @test !Autoloads.applydeferred!(ws.globalenv; output)
        end
        @testset "changes deferred while applying are kept" begin
            path = joinpath(Autoloads.statedir(), Autoloads.DEFERRED_FILE)
            Autoloads.defer!(VERSION, "resolve")
            applied = read(path, String)
            Autoloads.defer!(VERSION, "update", ["FixtureC"])
            Autoloads.dropapplied!(path, applied)
            @test deferred(VERSION) == ["update FixtureC"]
            Autoloads.dropapplied!(path, read(path, String))
            @test !isfile(path)
            Autoloads.dropapplied!(path, applied)
            @test !isfile(path)
        end
    finally
        rm(Autoloads.statedir(nextversion); recursive = true, force = true)
    end
end

@testset "the REPL extension's precompile workload leaves deferred changes alone" begin
    Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
    Autoloads.defer!(VERSION, "resolve")
    deferredfile = joinpath(Autoloads.statedir(), Autoloads.DEFERRED_FILE)
    try
        withenv("JULIA_PKG_OFFLINE" => "true") do
            Base.include(Ext, joinpath(AUTOLOADS_DIR, "ext", "AutoloadsREPLExt", "workload.jl"))
        end
        @test readlines(deferredfile) == ["resolve"]
    finally
        rm(deferredfile; force = true)
    end
end

@testset "adopting an older version's environment" begin
    env = freshglobalenv("""
        [deps]
        Autoloads = "$AUTOLOADS_UUID"

        [sources]
        Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
        """)
    output = IOBuffer()
    @test Autoloads.adoptprevious!(env.globaldir; output) === nothing
    @test !ispath(joinpath(env.globaldir, "autoloads"))
    siblingmember(env.globaldir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlibuuid("Dates"))\"\n")
    previous = withenv(() -> Autoloads.adoptprevious!(env.globaldir; output), "JULIA_DEPOT_PATH" => env.depotpath,
                       "JULIA_PKG_OFFLINE" => "true")
    @test previous.names == ["Dates"]
    @test membernames(joinpath(env.globaldir, "autoloads")) == ["Dates"]
    @test occursin("Created", String(take!(output)))
    @testset "by the session worker, once, then applying deferred changes" begin
        env = freshglobalenv("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        siblingmember(env.globaldir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlibuuid("Dates"))\"\n")
        Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
        member = joinpath(env.globaldir, "autoloads")
        worker = Ext.Worker(Ext.Runtime(Channel{Ext.Event}(Inf), member, joinpath(mktempdir(), "catalog")), Ext.Indexer())
        upkeep() = withenv(() -> Test.collect_test_logs(() -> Ext.maintainenvironment!(worker)) |> first,
                           "JULIA_DEPOT_PATH" => env.depotpath, "JULIA_PKG_OFFLINE" => "true")
        @test contains(only(upkeep()).message, "carrying over Dates")
        @test membernames(member) == ["Dates"]
        rm(member; recursive = true)
        @test isempty(upkeep()) && !ispath(member)
        mkpath(member)
        write(joinpath(member, "Project.toml"), "")
        Autoloads.defer!(VERSION, "resolve")
        @test isempty(upkeep())
        @test !isfile(joinpath(Autoloads.statedir(), Autoloads.DEFERRED_FILE))
    end
end

end
