using Test
using Autoloads: Config, PackageConfig, ConfigError, PrecompilePolicy, Bindings,
    Background, Lazy, AllBindings, UsedBindings, parse_config, package_config,
    bindings_for, autoload_names, PkgNames

error_text(f) = try; f(); "no error"; catch e; sprint(showerror, e); end

@testset "config defaults" begin
    cfg = parse_config(Dict{String, Any}())
    @test cfg.stdlib === false
    @test cfg.project == Set{String}()
    @test cfg.policy == Background
    @test cfg.bindings == AllBindings
    @test isempty(cfg.packages)
end

@testset "config keys" begin
    @test parse_config(Dict("stdlib" => true)).stdlib
    @test parse_config(Dict("project" => true)).project === nothing
    @test parse_config(Dict("project" => false)).project == Set{String}()
    @test parse_config(Dict("project" => Any["CSV", "Foo"])).project == Set(["CSV", "Foo"])
    @test parse_config(Dict("project" => ["CSV"])).project == Set(["CSV"])
    @test parse_config(Dict("precompile" => "lazy")).policy == Lazy
    @test parse_config(Dict("precompile" => "background")).policy == Background
    @test parse_config(Dict("bindings" => "used")).bindings == UsedBindings
    cfg = parse_config(Dict("bindings" => "used", "packages" => Dict(
        "DataFrames" => Dict("skip" => ["@btime", "x"], "only" => ["a"], "bindings" => "all"),
        "Plots" => Dict{String, Any}())))
    df = package_config(cfg, "DataFrames")
    @test df.skip == Set([Symbol("@btime"), :x])
    @test df.only == Set([:a])
    @test df.bindings == AllBindings
    @test bindings_for(cfg, "DataFrames") == AllBindings
    @test bindings_for(cfg, "Plots") == UsedBindings
    @test bindings_for(cfg, "Unlisted") == UsedBindings
    plain = package_config(cfg, "Unlisted")
    @test isempty(plain.skip) && plain.only === nothing && plain.bindings === nothing
end

@testset "config errors" begin
    bad(prefs) = error_text(() -> parse_config(prefs))
    @test_throws ConfigError parse_config(Dict("project" => "CSV"))
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
    r = PkgNames(id, VersionNumber[], Set([:Sub, :a, :b, Symbol("@btime")]), Set([:p]), Set([:r]))
    names(c) = autoload_names(r, c)
    @test names(PackageConfig(Set{Symbol}(), nothing, nothing)) == Set([:Sub, :a, :b, :r, Symbol("@btime")])
    @test names(PackageConfig(Set([:a, Symbol("@btime")]), nothing, nothing)) == Set([:Sub, :b, :r])
    @test names(PackageConfig(Set{Symbol}(), Set([:a]), nothing)) == Set([:Sub, :a])
    @test names(PackageConfig(Set([:Sub, :a]), Set([:b]), nothing)) == Set([:Sub, :b])
    @test :p ∉ names(PackageConfig(Set{Symbol}(), Set([:p]), nothing))
end
