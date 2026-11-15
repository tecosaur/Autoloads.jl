# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Autoloads: member_dir, catalog_path, project_deps, manifest_graph, dependency_closure,
    stdlib_ids, builtin_records, run_julia, notify_env_change, ENV_CHANGED, load_config,
    Config

const UUID_PKG = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const UUID_DATES = Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
const UUID_X = Base.UUID("00000000-0000-0000-0000-0000000000a1")
const UUID_Y = Base.UUID("00000000-0000-0000-0000-0000000000a2")

write_file(path, text) = (mkpath(dirname(path)); write(path, text); path)

function workspace_fixture(root)
    write_file(joinpath(root, "Project.toml"), """
        [deps]
        X = "$UUID_X"
        [workspace]
        projects = ["autoloads"]
        """)
    write_file(joinpath(root, "Manifest.toml"), """
        manifest_format = "2.0"
        julia_version = "1.12.0"
        [[deps.X]]
        uuid = "$UUID_X"
        version = "1.2.3"
        deps = ["Y"]
        [[deps.Y]]
        uuid = "$UUID_Y"
        version = "0.4.0"
        deps = ["Dates"]
        [[deps.Dates]]
        uuid = "$UUID_DATES"
        """)
    write_file(joinpath(root, "autoloads", "Project.toml"), """
        [deps]
        Y = "$UUID_Y"
        """)
end

@testset "member_dir and catalog_path" begin
    @test member_dir("/g") == joinpath("/g", "autoloads")
    tail = joinpath("julia", "autoloads", "v$(VERSION.major).$(VERSION.minor)", "catalog")
    withenv("XDG_STATE_HOME" => "/state") do
        @test catalog_path() == joinpath("/state", tail)
    end
    withenv("XDG_STATE_HOME" => "relative/state") do
        @test catalog_path() != joinpath("relative/state", tail) && endswith(catalog_path(), tail)
        @test isabspath(catalog_path())
    end
end

@testset "project_deps" begin
    mktempdir() do root
        workspace_fixture(root)
        @test project_deps(joinpath(root, "Project.toml")) == [Base.PkgId(UUID_X, "X")]
        @test project_deps(joinpath(root, "nonexistent", "Project.toml")) == Base.PkgId[]
    end
end

@testset "manifest_graph" begin
    mktempdir() do root
        workspace_fixture(root)
        for project in (joinpath(root, "Project.toml"), joinpath(root, "autoloads", "Project.toml"))
            g = manifest_graph(project)
            @test g.versions[UUID_X] == v"1.2.3"
            @test g.versions[UUID_DATES] === nothing
            @test g.deps[UUID_X] == [UUID_Y]
            @test g.deps[UUID_Y] == [UUID_DATES]
            @test dependency_closure(g, UUID_X) == Set([UUID_X, UUID_Y, UUID_DATES])
            @test dependency_closure(g, UUID_DATES) == Set([UUID_DATES])
        end
        empty = manifest_graph(joinpath(root, "nonexistent", "Project.toml"))
        @test isempty(empty.versions) && isempty(empty.deps)
        @test dependency_closure(empty, UUID_X) == Set([UUID_X])
    end
end

@testset "manifest_graph edge cases" begin
    mktempdir() do root
        project = write_file(joinpath(root, "Project.toml"), "")
        write_file(joinpath(root, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.X]]
            uuid = "$UUID_X"
            version = "1.0.0"
            """)
        versioned = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
        write_file(joinpath(root, versioned), """
            manifest_format = "2.0"
            [[deps.X]]
            uuid = "$UUID_X"
            version = "2.0.0"
            deps = ["Ghost"]
            [[deps.Y]]
            uuid = "$UUID_Y"
            version = "0.1.0"
            [deps.Y.deps]
            X = "$UUID_X"
            """)
        g = manifest_graph(project)
        @test g.versions[UUID_X] == v"2.0.0"
        @test g.deps[UUID_Y] == [UUID_X]
        @test g.deps[UUID_X] == Base.UUID[]
    end
end

@testset "stdlib_ids and builtin_records" begin
    ids = stdlib_ids()
    @test Base.PkgId(UUID_DATES, "Dates") in ids
    @test !any(id -> endswith(id.name, "_jll"), ids)
    @test any(r -> Symbol("@spawn") in r.exported, builtin_records())
end

@testset "run_julia" begin
    out = IOBuffer()
    wait(run_julia(`-e 'print(VERSION)'`; project = nothing, output = out))
    @test String(take!(out)) == string(VERSION)
    mktempdir() do dir
        write_file(joinpath(dir, "Project.toml"), "")
        wait(run_julia(`-e 'print(basename(dirname(Base.active_project())))'`;
                       project = dir, env = ("AUTOLOADS_X" => "1",), nice = true, output = out))
        @test String(take!(out)) == basename(dir)
    end
end

@testset "notify_env_change" begin
    calls = Ref(0)
    notify_env_change()
    ENV_CHANGED[] = () -> calls[] += 1
    try
        notify_env_change()
        @test calls[] == 1
    finally
        ENV_CHANGED[] = nothing
    end
end

@testset "load_config layers global and active preferences" begin
    repo = dirname(@__DIR__) |> dirname
    mktempdir() do dir
        deps = "Autoloads = \"62f4f456-9cf5-4553-a20f-e9d4789ac2f2\""
        global_project = joinpath(dir, "global")
        write_file(joinpath(global_project, "Project.toml"), """
            [deps]
            $deps
            [preferences.Autoloads]
            stdlib = true
            """)
        write_file(joinpath(global_project, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.Autoloads]]
            path = "$(escape_string(repo))"
            uuid = "62f4f456-9cf5-4553-a20f-e9d4789ac2f2"
            version = "0.1.0"
            """)
        with_extras = joinpath(dir, "with_extras")
        write_file(joinpath(with_extras, "Project.toml"), """
            [extras]
            $deps
            [preferences.Autoloads.packages.X]
            skip = ["y"]
            """)
        without_extras = joinpath(dir, "without_extras")
        write_file(joinpath(without_extras, "Project.toml"), """
            [preferences.Autoloads.packages.X]
            skip = ["y"]
            """)
        script = "using Autoloads; c = Autoloads.load_config(); " *
            "print(c.stdlib, ' ', join(sort!(collect(keys(c.packages))), ','))"
        facts(active) = begin
            out = IOBuffer()
            sep = Sys.iswindows() ? ";" : ":"
            load_path = join([active, global_project, "@stdlib"], sep)
            wait(run_julia(`-e $script`; project = active, output = out,
                           env = ("JULIA_LOAD_PATH" => load_path,)))
            String(take!(out))
        end
        @test facts(with_extras) == "true X"
        @test facts(without_extras) == "true "
    end
end
