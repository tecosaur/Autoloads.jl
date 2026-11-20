# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Autoloads: memberdir, catalogpath, statedir, projectdeps, manifestgraph, environment, dependencyclosure,
    stdlibids, builtinrecords, runjulia, notifyenvchange, ENV_CHANGED, loadconfig,
    Config

const UUID_PKG = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const UUID_DATES = Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
const UUID_X = Base.UUID("00000000-0000-0000-0000-0000000000a1")
const UUID_Y = Base.UUID("00000000-0000-0000-0000-0000000000a2")
const UUID_SELF = Base.UUID("00000000-0000-0000-0000-0000000000a3")

writefile(path, text) = (mkpath(dirname(path)); write(path, text); path)

function workspacefixture(root)
    writefile(joinpath(root, "Project.toml"), """
        [deps]
        X = "$UUID_X"
        [workspace]
        projects = ["autoloads"]
        """)
    writefile(joinpath(root, "Manifest.toml"), """
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
    writefile(joinpath(root, "autoloads", "Project.toml"), """
        [deps]
        Y = "$UUID_Y"
        """)
end

@testset "memberdir, catalogpath and statedir" begin
    @test memberdir("/g") == joinpath("/g", "autoloads")
    tail = joinpath("julia", "autoloads", "catalog")
    withenv("XDG_STATE_HOME" => "/state") do
        @test catalogpath() == joinpath("/state", tail)
        @test statedir(v"1.10.2") == joinpath("/state", "julia", "autoloads", "v1.10")
    end
    withenv("XDG_STATE_HOME" => "relative/state") do
        @test catalogpath() != joinpath("relative/state", tail) && endswith(catalogpath(), tail)
        @test isabspath(catalogpath())
    end
end

@testset "project_deps" begin
    mktempdir() do root
        workspacefixture(root)
        @test projectdeps(joinpath(root, "Project.toml")) == [Base.PkgId(UUID_X, "X")]
        @test projectdeps(joinpath(root, "nonexistent", "Project.toml")) == Base.PkgId[]
    end
end

@testset "manifest_graph" begin
    mktempdir() do root
        workspacefixture(root)
        for project in (joinpath(root, "Project.toml"), joinpath(root, "autoloads", "Project.toml"))
            g = manifestgraph(project)
            @test g.versions[UUID_X] == v"1.2.3"
            @test g.versions[UUID_DATES] === nothing
            @test g.deps[UUID_X] == [UUID_Y]
            @test g.deps[UUID_Y] == [UUID_DATES]
            @test dependencyclosure(g, UUID_X) == Set([UUID_X, UUID_Y, UUID_DATES])
            @test dependencyclosure(g, UUID_DATES) == Set([UUID_DATES])
        end
        empty = manifestgraph(joinpath(root, "nonexistent", "Project.toml"))
        @test isempty(empty.versions) && isempty(empty.deps)
        @test dependencyclosure(empty, UUID_X) == Set([UUID_X])
    end
end

@testset "manifestgraph edge cases" begin
    mktempdir() do root
        project = writefile(joinpath(root, "Project.toml"), "")
        writefile(joinpath(root, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.X]]
            uuid = "$UUID_X"
            version = "1.0.0"
            """)
        versioned = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
        writefile(joinpath(root, versioned), """
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
        g = manifestgraph(project)
        @test g.versions[UUID_X] == v"2.0.0"
        @test g.deps[UUID_Y] == [UUID_X]
        @test g.deps[UUID_X] == Base.UUID[]
    end
end

@testset "environment" begin
    mktempdir() do root
        workspacefixture(root)
        project = joinpath(root, "Project.toml")
        env = environment(project)
        @test env.deps == [Base.PkgId(UUID_X, "X")]
        @test env.graph.versions[UUID_X] == v"1.2.3"
        self = "name = \"Self\"\nuuid = \"$UUID_SELF\"\n"
        writefile(project, self * "version = \"0.3.1\"\n[deps]\nX = \"$UUID_X\"\n")
        env = environment(project)
        @test env.deps == [Base.PkgId(UUID_X, "X"), Base.PkgId(UUID_SELF, "Self")]
        @test env.graph.versions[UUID_SELF] == v"0.3.1"
        writefile(project, self)
        env = environment(project)
        @test env.deps == [Base.PkgId(UUID_SELF, "Self")]
        @test env.graph.versions[UUID_SELF] === nothing
        writefile(project, "name = \"Self\"\n")
        @test isempty(environment(project).deps)
        @test isempty(environment(joinpath(root, "nonexistent", "Project.toml")).deps)
        @test isempty(environment(nothing).deps)
    end
end

@testset "stdlibids and builtinrecords" begin
    ids = stdlibids()
    @test Base.PkgId(UUID_DATES, "Dates") in ids
    @test !any(id -> endswith(id.name, "_jll"), ids)
    @test any(r -> Symbol("@spawn") in r.exported, builtinrecords())
end

@testset "run_julia" begin
    out = IOBuffer()
    wait(runjulia(`-e 'print(VERSION)'`; project = nothing, output = out))
    @test String(take!(out)) == string(VERSION)
    mktempdir() do dir
        writefile(joinpath(dir, "Project.toml"), "")
        wait(runjulia(`-e 'print(basename(dirname(Base.active_project())))'`;
                       project = dir, env = ("AUTOLOADS_X" => "1",), nice = true, output = out))
        @test String(take!(out)) == basename(dir)
    end
end

@testset "notify_env_change" begin
    calls = Ref(0)
    notifyenvchange()
    ENV_CHANGED[] = () -> calls[] += 1
    try
        notifyenvchange()
        @test calls[] == 1
    finally
        ENV_CHANGED[] = nothing
    end
end

@testset "loadconfig layers global and active preferences" begin
    repo = dirname(@__DIR__) |> dirname
    mktempdir() do dir
        deps = "Autoloads = \"62f4f456-9cf5-4553-a20f-e9d4789ac2f2\""
        globalproject = joinpath(dir, "global")
        writefile(joinpath(globalproject, "Project.toml"), """
            [deps]
            $deps
            [preferences.Autoloads]
            stdlib = true
            """)
        writefile(joinpath(globalproject, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.Autoloads]]
            path = "$(escape_string(repo))"
            uuid = "62f4f456-9cf5-4553-a20f-e9d4789ac2f2"
            version = "0.1.0"
            """)
        withextras = joinpath(dir, "with_extras")
        writefile(joinpath(withextras, "Project.toml"), """
            [extras]
            $deps
            [preferences.Autoloads.packages.X]
            skip = ["y"]
            """)
        withoutextras = joinpath(dir, "without_extras")
        writefile(joinpath(withoutextras, "Project.toml"), """
            [preferences.Autoloads.packages.X]
            skip = ["y"]
            """)
        script = "using Autoloads; c = Autoloads.loadconfig(); " *
            "print(c.stdlib, ' ', join(sort!(collect(keys(c.packages))), ','))"
        facts(active) = begin
            out = IOBuffer()
            sep = Sys.iswindows() ? ";" : ":"
            loadpath = join([active, globalproject, "@stdlib"], sep)
            wait(runjulia(`-e $script`; project = active, output = out,
                           env = ("JULIA_LOAD_PATH" => loadpath,)))
            String(take!(out))
        end
        @test facts(withextras) == "true X"
        @test facts(withoutextras) == "true "
    end
end
