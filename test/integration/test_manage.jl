# A module keeps these helpers apart from the other test files' globals.
module TestManage

using Test, Autoloads
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
    @testset "carries over the newest older member" begin
        env = fresh_global_env("""
            [deps]
            Autoloads = "$AUTOLOADS_UUID"

            [sources]
            Autoloads = {path = "$(escape_string(AUTOLOADS_DIR))"}
            """)
        sibling_member(env.global_dir, PREVIOUS_ENV_NAME, """
            [deps]
            Dates = "$(stdlib_uuid("Dates"))"

            [compat]
            Dates = "1"
            """)
        sibling_member(env.global_dir, "v$(VERSION.major).$(VERSION.minor - 2)",
                       "[deps]\nPrintf = \"$(stdlib_uuid("Printf"))\"\n")
        sibling_member(env.global_dir, "v$(VERSION.major).$(VERSION.minor + 1)",
                       "[deps]\nPrintf = \"$(stdlib_uuid("Printf"))\"\n")
        captured(env.depot_path) do
            @test_logs Autoloads.init(; carry_over = true, global_dir = env.global_dir)
        end
        member = Base.parsed_toml(joinpath(env.global_dir, "autoloads", "Project.toml"))
        @test member["deps"] == Dict("Dates" => stdlib_uuid("Dates"))
        @test member["compat"] == Dict("Dates" => "1")
        @test Base.parsed_toml(joinpath(env.global_dir, "Project.toml"))["workspace"]["projects"] == ["autoloads"]
    end
    @test_throws ArgumentError Autoloads.init(; carry_over = :maybe, global_dir = mktempdir())
end

@testset "add, remove, update and status" begin
    ws = build_workspace(; fixtures = (FIXTURE_C,))
    catalog = joinpath(mktempdir(), "catalog-v1")
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
            @test notified[] == 5
            missing_member = (; global_dir = mktempdir(), catalog)
            @test_throws MemberMissing Autoloads.add(["FixtureA"]; missing_member...)
            @test occursin("autoloads init", sprint(showerror, MemberMissing(Autoloads.member_dir(missing_member.global_dir))))
        end
    finally
        Autoloads.ENV_CHANGED[] = nothing
    end
end

end
