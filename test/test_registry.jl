using Test
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Config, PackageConfig, parse_config,
    ManifestGraph, AllBindings, UsedBindings, Catalog, Registry, LoadRequest, build_catalog,
    records_of, names_at, failed_at, providers, autoload_set, build_registry, owner,
    is_candidate, ambiguities, pending_loads, to_index, builtin_records

pkg_id(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const ID_X, ID_Y, ID_Z = pkg_id("X", 1), pkg_id("Y", 2), pkg_id("Z", 3)

names_for(id, versions, exported = Symbol[]; public = Symbol[], reexported = Symbol[]) =
    PkgNames(id, VersionNumber.(versions), Set([Symbol(id.name); exported]), Set(public), Set(reexported))

cfg_of(; kwargs...) = parse_config(Dict{String, Any}(string(k) => v for (k, v) in kwargs))
no_graph = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(), Dict{Base.UUID, Vector{Base.UUID}}())
graph_of(pairs...) = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => v for (id, v) in pairs),
                                   Dict{Base.UUID, Vector{Base.UUID}}())
registry_of(records, autoload, cfg = cfg_of()) = build_registry(build_catalog(records), autoload, cfg)

@testset "catalog" begin
    a1 = names_for(ID_X, ["1.0.0"], [:f])
    a2 = names_for(ID_X, ["2.0.0"], [:f, :g])
    a1b = names_for(ID_X, ["1.1.0"], [:f])
    cat = build_catalog([a1, a2, a1b, PkgFailure(ID_Y, v"1.0.0", "boom")])
    @test names_at(cat, ID_X, v"1.1.0").versions == [v"1.0.0", v"1.1.0"]
    @test names_at(cat, ID_X, v"2.0.0") == a2
    @test names_at(cat, ID_X, v"3.0.0") === nothing
    @test names_at(cat, ID_X, nothing) == a2
    @test names_at(cat, ID_Z, nothing) === nothing
    @test length(records_of(cat, ID_X)) == 2
    @test isempty(records_of(cat, ID_Z))
    @test failed_at(cat, ID_Y, v"1.0.0").message == "boom"
    @test failed_at(cat, ID_Y, v"2.0.0") === nothing
    builtin = only(filter(r -> r.id.name == "Base.Threads", builtin_records()))
    @test names_at(build_catalog([builtin]), builtin.id, nothing) == builtin
    # newest record provides; providers sorted by package name; owns flag
    other = names_for(ID_Y, ["1.0.0"], Symbol[]; reexported = [:f])
    pc = build_catalog([a1, a2, other])
    @test providers(pc, :g) == [(ID_X, true)]
    @test providers(pc, :f) == [(ID_X, true), (ID_Y, false)]
    @test isempty(providers(pc, :nope))
    @test isempty(providers(build_catalog([names_for(ID_X, ["1.0.0"]; public = [:p])]), :p))
end

@testset "autoload_set" begin
    member = graph_of(ID_X => v"1.0.0")
    proj = graph_of(ID_X => v"2.0.0", ID_Y => v"1.0.0", ID_Z => nothing)
    stdlib = pkg_id("Std", 9)
    builtin = Base.PkgId(nothing, "Base.Threads")
    run(cfg) = autoload_set([ID_X], member, [ID_X, ID_Y, ID_Z], proj, [stdlib], [builtin], cfg)
    @test run(cfg_of()) == Dict(ID_X => v"1.0.0")
    @test run(cfg_of(project = true)) == Dict(ID_X => v"2.0.0", ID_Y => v"1.0.0", ID_Z => nothing)
    @test run(cfg_of(project = ["Y"])) == Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0")
    @test run(cfg_of(project = ["X"])) == Dict(ID_X => v"2.0.0")
    @test run(cfg_of(project = String[])) == Dict(ID_X => v"1.0.0")
    @test run(cfg_of(stdlib = true)) == Dict(ID_X => v"1.0.0", stdlib => nothing, builtin => nothing)
    @test autoload_set(Base.PkgId[], no_graph, Base.PkgId[], graph_of(stdlib => v"1.2.3"), [stdlib], Base.PkgId[],
                       cfg_of(stdlib = true)) == Dict(stdlib => v"1.2.3")
end

@testset "build_registry" begin
    auto(ids...) = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => nothing for id in ids)
    reg = registry_of([names_for(ID_X, ["1.0.0"], [:f]; public = [:p])], auto(ID_X))
    @test owner(reg, :f) == ID_X && owner(reg, :X) == ID_X
    @test !is_candidate(reg, :p) && owner(reg, :p) === nothing
    # owner beats re-exporter in both orders
    own = names_for(ID_X, ["1.0.0"], [:f]); re = names_for(ID_Y, ["1.0.0"]; reexported = [:f])
    for records in ([own, re], [re, own])
        r = registry_of(records, auto(ID_X, ID_Y))
        @test owner(r, :f) == ID_X && isempty(ambiguities(r))
    end
    # two owners, and two re-exporters with no owner, are ambiguous
    r = registry_of([own, names_for(ID_Y, ["1.0.0"], [:f])], auto(ID_X, ID_Y))
    @test !is_candidate(r, :f) && ambiguities(r)[:f] == [ID_X, ID_Y]
    r = registry_of([names_for(ID_X, ["1.0.0"]; reexported = [:f]), re], auto(ID_X, ID_Y))
    @test sort(ambiguities(r)[:f]; by = i -> i.name) == [ID_X, ID_Y]
    r = registry_of([names_for(ID_X, ["1.0.0"]; reexported = [:f])], auto(ID_X))
    @test owner(r, :f) == ID_X
    # version selection: exact record, else newest
    recs = [names_for(ID_X, ["1.0.0"], [:old]), names_for(ID_X, ["2.0.0"], [:new])]
    @test owner(registry_of(recs, Dict(ID_X => v"1.0.0")), :old) == ID_X
    @test owner(registry_of(recs, Dict(ID_X => v"3.0.0")), :new) == ID_X
    @test !is_candidate(registry_of(recs, Dict(ID_X => v"1.0.0")), :new)
    @test !is_candidate(registry_of(Any[], auto(ID_X)), :X)
    # skip / only
    skip = cfg_of(packages = Dict("X" => Dict("skip" => ["f"])))
    @test !is_candidate(registry_of([own], auto(ID_X), skip), :f)
    only_cfg = cfg_of(packages = Dict("X" => Dict("only" => ["g"])))
    r = registry_of([names_for(ID_X, ["1.0.0"], [:f, :g])], auto(ID_X), only_cfg)
    @test is_candidate(r, :g) && !is_candidate(r, :f) && is_candidate(r, :X)
    # stdlib overrides use the same packages table
    dist = pkg_id("Distributed", 7)
    spawn = Symbol("@spawn")
    threads = only(filter(r -> r.id.name == "Base.Threads", builtin_records()))
    records = [names_for(dist, ["1.0.0"], [spawn]), threads]
    wanted = auto(dist, threads.id)
    r = registry_of(records, wanted)
    @test haskey(ambiguities(r), spawn)
    r = registry_of(records, wanted, cfg_of(packages = Dict("Distributed" => Dict("skip" => ["@spawn"]))))
    @test owner(r, spawn) == threads.id
end

@testset "pending_loads" begin
    reg = registry_of([names_for(ID_X, ["1.0.0"], [:f, :g]), names_for(ID_Y, ["1.0.0"], [:h])],
                      Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    none = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    unbound = _ -> false
    attempted_of(pairs...) = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(pairs)
    all_cfg = cfg_of()
    used_cfg = cfg_of(bindings = "used")
    @test pending_loads(reg, all_cfg, [:f, :g, :h, :zzz], unbound, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, nothing)]
    @test pending_loads(reg, used_cfg, [:f, :g, :zzz], unbound, none) ==
          [LoadRequest(ID_X, :f, :f), LoadRequest(ID_X, :g, :g)]
    @test pending_loads(reg, used_cfg, [:f, :g], ==(:f), none) == [LoadRequest(ID_X, :g, :g)]
    @test isempty(pending_loads(reg, all_cfg, [:f], unbound, attempted_of((ID_X, nothing))))
    @test pending_loads(reg, used_cfg, [:f, :g], unbound, attempted_of((ID_X, :f))) == [LoadRequest(ID_X, :g, :g)]
    mixed = cfg_of(packages = Dict("Y" => Dict("bindings" => "used")))
    @test pending_loads(reg, mixed, [:f, :g, :h], unbound, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, :h)]
end

@testset "to_index" begin
    cat = build_catalog([names_for(ID_X, ["1.0.0"]), PkgFailure(ID_Y, v"1.0.0", "boom"),
                         names_for(ID_Z, ["1.0.0"])])
    wanted = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(
        ID_X => v"1.0.0", ID_Y => v"1.0.0", ID_Z => v"2.0.0")
    @test to_index(cat, wanted) == [ID_Z]
    @test to_index(cat, Dict(ID_X => v"2.0.0", ID_Y => v"2.0.0")) == [ID_X, ID_Y]
    # version nothing: any record covers it
    @test isempty(to_index(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(ID_X => nothing)))
    @test to_index(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(pkg_id("W", 4) => nothing)) == [pkg_id("W", 4)]
end
