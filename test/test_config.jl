# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Autoloads: Sighting, JULIA_MINOR, Config, PackageConfig, ConfigError, PrecompilePolicy, Bindings,
    Background, Lazy, AllBindings, UsedBindings, parseconfig, packageconfig,
    autoloadnames, PkgNames

errortext(f) = try; f(); "no error"; catch e; sprint(showerror, e); end

@testset "config defaults" begin
    cfg = parseconfig(Dict{String, Any}())
    @test cfg.stdlib === true
    @test cfg.project === nothing
    @test cfg.policy == Background
    @test cfg.bindings == AllBindings
    @test cfg.log === false
    @test cfg.uphook === true
    @test isempty(cfg.packages)
end

@testset "config keys" begin
    @test parseconfig(Dict("stdlib" => true)).stdlib
    @test parseconfig(Dict("project" => true)).project === nothing
    @test parseconfig(Dict("project" => false)).project == Set{String}()
    @test parseconfig(Dict("project" => Any["CSV", "Foo"])).project == Set(["CSV", "Foo"])
    @test parseconfig(Dict("project" => ["CSV"])).project == Set(["CSV"])
    @test parseconfig(Dict("precompile" => "lazy")).policy == Lazy
    @test parseconfig(Dict("precompile" => "background")).policy == Background
    @test parseconfig(Dict("bindings" => "used")).bindings == UsedBindings
    @test parseconfig(Dict("log" => true)).log === true
    @test parseconfig(Dict("up_hook" => false)).uphook === false
    cfg = parseconfig(Dict("bindings" => "used", "packages" => Dict(
        "DataFrames" => Dict("skip" => ["@btime", "x"], "only" => ["a"], "bindings" => "all"),
        "Plots" => Dict{String, Any}())))
    df = packageconfig(cfg, "DataFrames")
    @test df.skip == Set([Symbol("@btime"), :x])
    @test df.only == Set([:a])
    @test df.bindings == AllBindings
    @test cfg.bindings == UsedBindings && packageconfig(cfg, "Plots").bindings === nothing
    plain = packageconfig(cfg, "Unlisted")
    @test isempty(plain.skip) && plain.only === nothing && plain.bindings === nothing
end

@testset "config errors" begin
    bad(prefs) = errortext(() -> parseconfig(prefs))
    @test_throws ConfigError parseconfig(Dict("project" => "CSV"))
    @test occursin("`project`", bad(Dict("project" => "CSV")))
    @test occursin("found 3 (Int64)", bad(Dict("project" => 3)))
    @test occursin("`stdlib`", bad(Dict("stdlib" => "yes")))
    @test occursin("`precompile`", bad(Dict("precompile" => "eager")))
    @test occursin("`bindings`", bad(Dict("bindings" => "some")))
    @test occursin("`project`", bad(Dict("project" => Any["a", 1])))
    msg = bad(Dict("packages" => Dict("DataFrames" => Dict("skip" => 3))))
    @test msg == "Autoloads preference `packages.DataFrames.skip` should be a list of names, found 3 (Int64). " *
        "Fix [preferences.Autoloads] in the global environment's Project.toml or LocalPreferences.toml (or the active project's, if it overrides it)."
    @test occursin("`packages.P.bindings`", bad(Dict("packages" => Dict("P" => Dict("bindings" => "x")))))
    @test occursin("`packages.P`", bad(Dict("packages" => Dict("P" => 1))))
    @test occursin("`packages`", bad(Dict("packages" => 1)))
    unknown = bad(Dict("skipp" => 1))
    @test occursin("`skipp`", unknown) && occursin("stdlib", unknown) && occursin("precompile", unknown)
    nested = bad(Dict("packages" => Dict("P" => Dict("skipp" => 1))))
    @test occursin("`packages.P.skipp`", nested) && occursin("skip", nested)
end

@testset "autoload_names" begin
    id = Base.PkgId(Base.UUID("11111111-2222-3333-4444-555555555555"), "Pkg.Sub")
    at = Sighting[(; version = nothing, julia = JULIA_MINOR)]
    r = PkgNames(id, at, Set([:Sub, :a, :b, Symbol("@btime")]), Set([:p]), Set([:r]))
    names(c) = autoloadnames(r, c)
    @test names(PackageConfig(Set{Symbol}(), nothing, nothing)) == Set([:Sub, :a, :b, :r, Symbol("@btime")])
    @test names(PackageConfig(Set([:a, Symbol("@btime")]), nothing, nothing)) == Set([:Sub, :b, :r])
    @test names(PackageConfig(Set{Symbol}(), Set([:a]), nothing)) == Set([:Sub, :a])
    @test names(PackageConfig(Set([:Sub, :a]), Set([:b]), nothing)) == Set([:Sub, :b])
    @test :p ∉ names(PackageConfig(Set{Symbol}(), Set([:p]), nothing))
end
