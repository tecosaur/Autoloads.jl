# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestManage

using Test, REPL, Future, Autoloads
using Autoloads: PkgNames, PkgFailure, PkgOperationFailed, MemberMissing, read_catalog,
    write_catalog_changes!, project_deps

include("setup.jl")

const AUTOLOADS_DIR = dirname(dirname(@__DIR__))
const AUTOLOADS_UUID = Base.PkgId(Autoloads).uuid
const ENV_NAME = "v$(VERSION.major).$(VERSION.minor)"
const PREVIOUS_ENV_NAME = "v$(VERSION.major).$(VERSION.minor - 1)"

stdlib_uuid(name) = Base.parsed_toml(joinpath(Sys.STDLIB, name, "Project.toml"))["uuid"]

"A fresh depot with a global environment whose Project.toml is `project`; returns `(; depot_path, global_dir)`."
function fresh_global_env(project)
    depot = mktempdir()
    global_dir = joinpath(depot, "environments", ENV_NAME)
    mkpath(global_dir)
    write(joinpath(global_dir, "Project.toml"), project)
    (; depot_path = join([depot; DEPOT_PATH], Sys.iswindows() ? ';' : ':'), global_dir)
end

"Write an autoloads member for the sibling environment `name` of `global_dir`."
function sibling_member(global_dir, name, project)
    dir = joinpath(dirname(global_dir), name, "autoloads")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), project)
end

"Run `f` with Pkg subprocesses offline in `depot_path`; returns `f()` and everything printed to stdout."
function captured(f, depot_path)
    mktemp() do path, io
        value = withenv("JULIA_DEPOT_PATH" => depot_path, "JULIA_PKG_OFFLINE" => "true",
                        "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing) do
            redirect_stdout(f, io)
        end
        flush(io)
        value, read(path, String)
    end
end

"A git repository, on branch `main`, holding a copy of fixture `name`."
function git_fixture(name)
    repo = mktempdir()
    cp(joinpath(FIXTURES_DIR, name), repo; force = true)
    git = `git -C $repo -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false`
    run(pipeline(`git init -q -b main $repo`; stdout = devnull))
    run(`$git add -A`)
    run(`$git commit -qm $name`)
    repo
end

member_names(member) = sort!([id.name for id in project_deps(joinpath(member, "Project.toml"))])

@testset "init" begin
    @testset "creates the member, preserving the global project" begin
        env = fresh_global_env("""
            [deps]
            Printf = "$(stdlib_uuid("Printf"))"

            [workspace]
            projects = ["x"]
            """)
        mkpath(joinpath(env.global_dir, "x"))
        write(joinpath(env.global_dir, "x", "Project.toml"), "")
        sibling_member(env.global_dir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlib_uuid("Dates"))\"\n")
        project_file = joinpath(env.global_dir, "Project.toml")
        notified = Ref(0)
        Autoloads.ENV_CHANGED[] = () -> notified[] += 1
        try
            _, output = captured(env.depot_path) do
                @test_logs (:warn, r"does not depend on Autoloads") Autoloads.init(; global_dir = env.global_dir)
            end
            project = Base.parsed_toml(project_file)
            @test project["deps"] == Dict("Printf" => stdlib_uuid("Printf"))
            @test project["workspace"]["projects"] == ["x", "autoloads"]
            @test isfile(joinpath(env.global_dir, "autoloads", "Project.toml"))
            @test isfile(joinpath(env.global_dir, "Manifest.toml"))
            @test occursin("Created", output)
            @testset "a non-interactive :ask only says how to carry over" begin
                @test isempty(member_names(joinpath(env.global_dir, "autoloads")))
                @test occursin("autoloads add Dates", output)
            end
            @test notified[] == 1
            bytes = read(project_file)
            _, output = captured(env.depot_path) do
                @test_logs (:warn, r"does not depend on Autoloads") Autoloads.init(; global_dir = env.global_dir)
            end
            @test occursin("already", output) && !occursin("Created", output)
            @test read(project_file) == bytes
            @test notified[] == 2
        finally
            Autoloads.ENV_CHANGED[] = nothing
        end
    end
    @testset "add creates a missing member first" begin
        env = fresh_global_env("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        _, output = captured(() -> Autoloads.add([joinpath(FIXTURES_DIR, "FixtureA")]; global_dir = env.global_dir,
                                                 catalog = joinpath(mktempdir(), "catalog")), env.depot_path)
        @test occursin("Created", output)
        @test member_names(joinpath(env.global_dir, "autoloads")) == ["FixtureA"]
        @testset "and adds from a git URL" begin
            url = "file://" * git_fixture("FixtureC")
            captured(() -> Autoloads.add("$url#main"; global_dir = env.global_dir,
                                         catalog = joinpath(mktempdir(), "catalog")), env.depot_path)
            member = Base.parsed_toml(joinpath(env.global_dir, "autoloads", "Project.toml"))
            @test haskey(member["deps"], "FixtureC")
            @test VERSION < v"1.13-" || member["sources"]["FixtureC"] == Dict("url" => url, "rev" => "main")
        end
    end
    @testset "carries over the newest older member" begin
        env = fresh_global_env("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        previous_root = joinpath(dirname(env.global_dir), PREVIOUS_ENV_NAME)
        fixture_a = joinpath(FIXTURES_DIR, "FixtureA")
        # FixtureA has a relative `[sources]` path; FixtureB's git source is in the manifest only.
        sibling_member(env.global_dir, PREVIOUS_ENV_NAME, """
            [deps]
            Dates = "$(stdlib_uuid("Dates"))"
            FixtureA = "$(FIXTURE_A.uuid)"
            FixtureB = "$(FIXTURE_B.uuid)"

            [compat]
            Dates = "1"
            FixtureA = "0.1"
            julia = "1.10"

            [sources]
            FixtureA = {path = "$(escape_string(relpath(fixture_a, joinpath(previous_root, "autoloads"))))"}
            """)
        repo = git_fixture("FixtureB")
        write(joinpath(previous_root, "Project.toml"),
              "[workspace]\nprojects = [\"autoloads\"]\n\n[preferences.Autoloads]\nlog = true\n")
        write(joinpath(previous_root, "LocalPreferences.toml"), "[Autoloads]\nstdlib = false\n")
        write(joinpath(previous_root, "Manifest.toml"), """
            manifest_format = "2.0"

            [[deps.Dates]]
            uuid = "$(stdlib_uuid("Dates"))"

            [[deps.FixtureA]]
            path = "$(escape_string(fixture_a))"
            uuid = "$(FIXTURE_A.uuid)"
            version = "0.1.0"

            [[deps.FixtureB]]
            deps = ["FixtureA"]
            repo-rev = "main"
            repo-url = "$(escape_string(repo))"
            uuid = "$(FIXTURE_B.uuid)"
            version = "0.1.0"
            """)
        sibling_member(env.global_dir, "v$(VERSION.major).$(VERSION.minor - 2)",
                       "[deps]\nPrintf = \"$(stdlib_uuid("Printf"))\"\n")
        sibling_member(env.global_dir, "v$(VERSION.major).$(VERSION.minor + 1)",
                       "[deps]\nPrintf = \"$(stdlib_uuid("Printf"))\"\n")
        _, output = captured(env.depot_path) do
            @test_logs Autoloads.init(; carry_over = true, global_dir = env.global_dir)
        end
        member = Base.parsed_toml(joinpath(env.global_dir, "autoloads", "Project.toml"))
        @test member["deps"] == Dict("Dates" => stdlib_uuid("Dates"), "FixtureA" => string(FIXTURE_A.uuid),
                                     "FixtureB" => string(FIXTURE_B.uuid))
        @test member["compat"] == Dict("Dates" => "1", "FixtureA" => "0.1", "julia" => "1.10")
        @test member["sources"] == Dict("FixtureA" => Dict("path" => fixture_a),
                                        "FixtureB" => Dict("url" => repo, "rev" => "main"))
        @test occursin("carrying over 3 packages", output)
        global_project = Base.parsed_toml(joinpath(env.global_dir, "Project.toml"))
        @test global_project["workspace"]["projects"] == ["autoloads"]
        @testset "with the preferences" begin
            @test global_project["preferences"]["Autoloads"] == Dict("log" => true)
            @test Base.parsed_toml(joinpath(env.global_dir, "LocalPreferences.toml")) ==
                Dict("Autoloads" => Dict("stdlib" => false))
        end
    end
    @testset "a failed resolve leaves the global environment as it was" begin
        env = fresh_global_env("[deps]\nPrintf = \"$(stdlib_uuid("Printf"))\"\n")
        sibling_member(env.global_dir, PREVIOUS_ENV_NAME,
                       "[deps]\nNotRegistered = \"0d0d0d0d-4444-4444-8444-00000000000d\"\n")
        project_file = joinpath(env.global_dir, "Project.toml")
        bytes = read(project_file)
        err = try
            captured(() -> Autoloads.init(; carry_over = true, global_dir = env.global_dir), env.depot_path)
            nothing
        catch err
            err
        end
        @test err isa PkgOperationFailed && err.op === :init && err.env == env.global_dir
        @test occursin(env.global_dir, sprint(showerror, err))
        @test read(project_file) == bytes
        @test !ispath(joinpath(env.global_dir, "autoloads"))
        @test readdir(env.global_dir) == ["Project.toml"]
        @testset "and init can run again" begin
            captured(env.depot_path) do
                @test_logs (:warn,) Autoloads.init(; carry_over = false, global_dir = env.global_dir)
            end
            @test isfile(joinpath(env.global_dir, "autoloads", "Project.toml"))
        end
    end
    @test_throws ArgumentError Autoloads.init(; carry_over = :maybe, global_dir = mktempdir())
end

@testset "add, remove, update and status" begin
    ws = build_workspace(; fixtures = (FIXTURE_C,))
    catalog = joinpath(mktempdir(), "catalog")
    global_dir = ws.global_env
    kws = (; global_dir, catalog)
    status_text() = sprint(io -> Autoloads.status(io; kws...))
    fixture_path(id) = joinpath(FIXTURES_DIR, id.name)
    notified = Ref(0)
    Autoloads.ENV_CHANGED[] = () -> notified[] += 1
    try
        @testset "add" begin
            captured(() -> Autoloads.add([fixture_path(FIXTURE_A)]; kws...), ws.depot_path)
            @test member_names(ws.member) == ["FixtureA", "FixtureC"]
            @test notified[] == 1
            @test occursin(r"FixtureA v0\.1\.0 +not indexed", status_text())
            write_catalog_changes!(catalog, Autoloads.CatalogRecord[
                PkgNames(FIXTURE_A, [v"0.1.0"], Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST]),
                         Set([:fa_public]), Set{Symbol}()),
                PkgFailure(FIXTURE_C, v"0.1.0", "FixtureC failed to load\nStacktrace: ...")])
            text = status_text()
            @test occursin(r"FixtureA v0\.1\.0 +indexed \(4 names\)", text)
            @test occursin(r"FixtureC v0\.1\.0 +failed: FixtureC failed to load\n", text)
        end
        @testset "re-adding a failed package clears its failure" begin
            captured(() -> Autoloads.add([fixture_path(FIXTURE_C)]; kws...), ws.depot_path)
            @test !any(r -> r isa PkgFailure, read_catalog(catalog))
            @test count(r -> r isa PkgNames, read_catalog(catalog)) == 1
            @test occursin(r"FixtureC v0\.1\.0 +not indexed", status_text())
            @test notified[] == 2
        end
        @testset "status" begin
            write_catalog_changes!(catalog, Autoloads.CatalogRecord[
                PkgNames(FIXTURE_C, [v"0.1.0"], Set([:FixtureC, :fa]), Set{Symbol}(), Set{Symbol}())])
            text = status_text()
            @test occursin("Global autoloads", text) && occursin("Project autoloads", text)
            @test occursin(r"Ambiguous names:\n +fa: FixtureA, FixtureC\n", text)
            @test occursin("Precompile policy: background", text)
            @test occursin(ws.member, text)
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
                    @test occursin(r"Project autoloads.*\n +FixtureB +not indexed\n", status_text())
                finally
                    Base.set_active_project(before)
                end
            end
        end
        @testset "update" begin
            captured(() -> Autoloads.update(; global_dir), ws.depot_path)
            captured(() -> Autoloads.update(["FixtureC"]; global_dir), ws.depot_path)
            @test member_names(ws.member) == ["FixtureA", "FixtureC"]
            @test notified[] == 4
        end
        @testset "remove" begin
            captured(() -> Autoloads.remove(["FixtureA"]; global_dir), ws.depot_path)
            @test member_names(ws.member) == ["FixtureC"]
            @test !occursin("FixtureA", status_text())
            @test notified[] == 5
        end
        @testset "failures" begin
            err = try
                captured(() -> Autoloads.remove(["NotAPackage"]; global_dir), ws.depot_path)
                nothing
            catch err
                err
            end
            @test err isa PkgOperationFailed && err.op === :remove && err.pkgs == ["NotAPackage"]
            @test occursin("NotAPackage", sprint(showerror, err))
            @test occursin(ws.member, sprint(showerror, err))
            @test notified[] == 5
            @testset "a partly failed add still notifies" begin
                err = try
                    captured(() -> Autoloads.add([fixture_path(FIXTURE_A), "NotAPackage"]; kws...), ws.depot_path)
                    nothing
                catch err
                    err
                end
                @test err isa PkgOperationFailed && err.op === :add
                @test member_names(ws.member) == ["FixtureA", "FixtureC"]
                @test notified[] == 6
            end
            missing_member = (; global_dir = mktempdir(), catalog)
            @testset "names as separate arguments" begin
                @test_throws MemberMissing Autoloads.remove("FixtureA"; missing_member.global_dir)
                @test_throws MemberMissing Autoloads.update("FixtureA"; missing_member.global_dir)
                @test_throws ArgumentError Autoloads.add(; missing_member...)
            end
            @test occursin("autoloads init", sprint(showerror, MemberMissing(Autoloads.member_dir(missing_member.global_dir))))
        end
    finally
        Autoloads.ENV_CHANGED[] = nothing
    end
end

@testset "all Julia versions" begin
    ws = build_workspace(; fixtures = (FIXTURE_C,))
    kws = (; global_dir = ws.global_env, catalog = joinpath(mktempdir(), "catalog"))
    next_version = VersionNumber(VERSION.major, VERSION.minor + 1)
    sibling_member(ws.global_env, "v$(next_version.major).$(next_version.minor)",
                   "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
    sibling = joinpath(dirname(ws.global_env), "v$(next_version.major).$(next_version.minor)", "autoloads")
    deferred(version) = (path = joinpath(Autoloads.state_dir(version), Autoloads.DEFERRED_FILE);
                         isfile(path) ? readlines(path) : String[])
    fixture_a = joinpath(FIXTURES_DIR, "FixtureA")
    try
        @testset "add and remove edit the other versions now, and defer their resolve" begin
            captured(() -> Autoloads.add([fixture_a]; all_versions = true, kws...), ws.depot_path)
            sibling_project = Base.parsed_toml(joinpath(sibling, "Project.toml"))
            @test member_names(sibling) == ["FixtureA", "FixtureC"]
            @test sibling_project["sources"]["FixtureA"] == Dict("path" => fixture_a)
            @test deferred(next_version) == ["resolve"]
            captured(() -> Autoloads.add([fixture_a]; all_versions = true, kws...), ws.depot_path)
            @test deferred(next_version) == ["resolve"]  # unchanged, so nothing more to resolve
            captured(() -> Autoloads.remove(["FixtureA"]; all_versions = true, kws.global_dir), ws.depot_path)
            @test member_names(ws.member) == member_names(sibling) == ["FixtureC"]
            @test !haskey(Base.parsed_toml(joinpath(sibling, "Project.toml")), "sources")
            @test deferred(next_version) == ["resolve", "resolve"]
            @testset "a package only another version has" begin
                sibling_member(ws.global_env, "v$(next_version.major).$(next_version.minor)",
                               "[deps]\nFixtureB = \"$(FIXTURE_B.uuid)\"\n")
                captured(() -> Autoloads.remove("FixtureB"; all_versions = true, kws.global_dir), ws.depot_path)
                @test isempty(member_names(sibling)) && member_names(ws.member) == ["FixtureC"]
            end
        end
        @testset "update defers an update" begin
            captured(() -> Autoloads.update(["FixtureC"]; all_versions = true, kws.global_dir), ws.depot_path)
            @test last(deferred(next_version)) == "update FixtureC"
        end
        @testset "deferred changes apply once" begin
            Autoloads.defer!(VERSION, "resolve")
            Autoloads.defer!(VERSION, "update", ["FixtureC"])
            output = IOBuffer()
            @test withenv(() -> Autoloads.apply_deferred!(ws.global_env; output), "JULIA_DEPOT_PATH" => ws.depot_path,
                          "JULIA_PKG_OFFLINE" => "true")
            @test isempty(deferred(VERSION))
            @test !Autoloads.apply_deferred!(ws.global_env; output)
        end
    finally
        rm(Autoloads.state_dir(next_version); recursive = true, force = true)
    end
end

@testset "adopting an older version's environment" begin
    env = fresh_global_env("""
        [deps]
        Autoloads = "$AUTOLOADS_UUID"

        [sources]
        Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
        """)
    output = IOBuffer()
    @test Autoloads.adopt_previous!(env.global_dir; output) === nothing
    @test !ispath(joinpath(env.global_dir, "autoloads"))
    sibling_member(env.global_dir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlib_uuid("Dates"))\"\n")
    previous = withenv(() -> Autoloads.adopt_previous!(env.global_dir; output), "JULIA_DEPOT_PATH" => env.depot_path,
                       "JULIA_PKG_OFFLINE" => "true")
    @test previous.names == ["Dates"]
    @test member_names(joinpath(env.global_dir, "autoloads")) == ["Dates"]
    @test occursin("Created", String(take!(output)))
    @testset "by the session worker, once, then applying deferred changes" begin
        env = fresh_global_env("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        sibling_member(env.global_dir, PREVIOUS_ENV_NAME, "[deps]\nDates = \"$(stdlib_uuid("Dates"))\"\n")
        Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
        member = joinpath(env.global_dir, "autoloads")
        worker = Ext.Worker(Ext.Runtime(Channel{Ext.Event}(Inf), member, joinpath(mktempdir(), "catalog")), Ext.Indexer())
        upkeep() = withenv(() -> Test.collect_test_logs(() -> Ext.maintain_environment!(worker)) |> first,
                           "JULIA_DEPOT_PATH" => env.depot_path, "JULIA_PKG_OFFLINE" => "true")
        @test contains(only(upkeep()).message, "carrying over Dates")
        @test member_names(member) == ["Dates"]
        rm(member; recursive = true)
        @test isempty(upkeep()) && !ispath(member)
        mkpath(member)
        write(joinpath(member, "Project.toml"), "")
        Autoloads.defer!(VERSION, "resolve")
        @test isempty(upkeep())
        @test !isfile(joinpath(Autoloads.state_dir(), Autoloads.DEFERRED_FILE))
    end
end

end
