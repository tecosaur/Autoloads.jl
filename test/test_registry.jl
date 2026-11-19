# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Sighting, JULIA_MINOR, Config, PackageConfig, parse_config,
    ManifestGraph, AllBindings, UsedBindings, Catalog, Registry, LoadRequest, build_catalog,
    records_of, names_at, failed_at, providers, autoload_set, build_registry, owner,
    is_candidate, pending_loads, to_index, builtin_records

pkg_id(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const ID_X, ID_Y, ID_Z = pkg_id("X", 1), pkg_id("Y", 2), pkg_id("Z", 3)

names_for(id, versions, exported = Symbol[]; public = Symbol[], reexported = Symbol[], origin = nothing,
          julia = JULIA_MINOR) =
    PkgNames(id, Sighting[(; version = VersionNumber(v), julia) for v in versions], Set([Symbol(id.name); exported]),
             Set(public), Set(reexported);
             origins = Dict{Symbol, Base.PkgId}(name => origin for name in reexported if origin !== nothing))

failure_for(id, version; julia = JULIA_MINOR) = PkgFailure(id, Sighting[(; version, julia)], "boom")

# Neither stdlibs nor the project autoload unless a test asks.
cfg_of(; kwargs...) = parse_config(Dict{String, Any}("stdlib" => false, "project" => false,
                                                     (string(k) => v for (k, v) in kwargs)...))
no_graph = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(), Dict{Base.UUID, Vector{Base.UUID}}())
graph_of(pairs...) = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => v for (id, v) in pairs),
                                   Dict{Base.UUID, Vector{Base.UUID}}())
registry_of(records, autoload, cfg = cfg_of()) = build_registry(build_catalog(records), autoload, cfg)

@testset "catalog" begin
    a1 = names_for(ID_X, ["1.0.0"], [:f])
    a2 = names_for(ID_X, ["2.0.0"], [:f, :g])
    a1b = names_for(ID_X, ["1.1.0"], [:f])
    cat = build_catalog([a1, a2, a1b, failure_for(ID_Y, v"1.0.0")])
    @test names_at(cat, ID_X, v"1.1.0").at == Sighting[(; version, julia = JULIA_MINOR) for version in (v"1.0.0", v"1.1.0")]
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

@testset "lookups from another Julia minor" begin
    older = names_for(ID_X, ["1.0.0"], [:old]; julia = v"1.11")
    near = names_for(ID_X, ["1.0.0"], [:near]; julia = v"1.12")
    newer = names_for(ID_X, ["1.0.0"], [:new]; julia = v"1.14")
    from(julia, records...) = build_catalog(collect(CatalogRecord, records); julia)
    @test names_at(from(v"1.12", older, near, newer), ID_X, v"1.0.0") == near
    @test names_at(from(v"1.13", older, near, newer), ID_X, v"1.0.0") == near
    @test names_at(from(v"1.13", older, newer), ID_X, v"1.0.0") == older
    @test names_at(from(v"1.13", newer), ID_X, v"1.0.0") == newer
    @test names_at(from(v"1.13", near), ID_X, v"2.0.0") === nothing
    @test providers(from(v"1.13", older, newer), :old) == [(ID_X, true)]
    # This minor's records come first, whatever the version.
    here = names_for(ID_X, ["1.0.0"], [:here]; julia = v"1.13")
    later = names_for(ID_X, ["2.0.0"], [:later]; julia = v"1.12")
    @test names_at(from(v"1.13", here, later), ID_X, nothing) == here
    @testset "a stand-in is still indexed, and failures stay with their minor" begin
        cat = from(v"1.13", near, failure_for(ID_Y, v"1.0.0"; julia = v"1.12"))
        @test failed_at(cat, ID_Y, v"1.0.0") === nothing
        @test to_index(cat, Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0")) == [ID_X, ID_Y]
        @test to_index(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(ID_X => nothing)) == [ID_X]
    end
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
        @test owner(r, :f) == ID_X && isempty(r.ambiguous)
    end
    # two owners, and two re-exporters with no owner, are ambiguous
    r = registry_of([own, names_for(ID_Y, ["1.0.0"], [:f])], auto(ID_X, ID_Y))
    @test !is_candidate(r, :f) && r.ambiguous[:f] == [ID_X, ID_Y]
    r = registry_of([names_for(ID_X, ["1.0.0"]; reexported = [:f]), re], auto(ID_X, ID_Y))
    @test sort(r.ambiguous[:f]; by = i -> i.name) == [ID_X, ID_Y]
    r = registry_of([names_for(ID_X, ["1.0.0"]; reexported = [:f])], auto(ID_X))
    @test owner(r, :f) == ID_X
    # re-exporters of one known origin share the name, unless the origin autoloads too
    from(id, origin) = names_for(id, ["1.0.0"]; reexported = [:f], origin)
    r = registry_of([from(ID_X, ID_Z), from(ID_Y, ID_Z)], auto(ID_X, ID_Y))
    @test r.shared[:f] == [ID_X, ID_Y] && is_candidate(r, :f) && owner(r, :f) === nothing && isempty(r.ambiguous)
    r = registry_of([from(ID_X, ID_Z), from(ID_Y, ID_Z), names_for(ID_Z, ["1.0.0"], [:f])], auto(ID_X, ID_Y, ID_Z))
    @test owner(r, :f) == ID_Z && isempty(r.shared)
    for other in (ID_X, nothing)
        r = registry_of([from(ID_X, ID_Z), from(ID_Y, other)], auto(ID_X, ID_Y))
        @test haskey(r.ambiguous, :f) && isempty(r.shared)
    end
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
    @test haskey(r.ambiguous, spawn)
    r = registry_of(records, wanted, cfg_of(packages = Dict("Distributed" => Dict("skip" => ["@spawn"]))))
    @test owner(r, spawn) == threads.id
end

@testset "pending_loads" begin
    reg = registry_of([names_for(ID_X, ["1.0.0"], [:f, :g]), names_for(ID_Y, ["1.0.0"], [:h])],
                      Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    none = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    unbound = unloaded = Returns(false)
    attempted_of(pairs...) = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(pairs)
    all_cfg = cfg_of()
    used_cfg = cfg_of(bindings = "used")
    @test pending_loads(reg, all_cfg, [:f, :g, :h, :zzz], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, nothing)]
    @test pending_loads(reg, used_cfg, [:f, :g, :zzz], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, :f), LoadRequest(ID_X, :g, :g)]
    @test pending_loads(reg, used_cfg, [:f, :g], ==(:f), unloaded, none) == [LoadRequest(ID_X, :g, :g)]
    @test isempty(pending_loads(reg, all_cfg, [:f], unbound, unloaded, attempted_of((ID_X, nothing))))
    @test pending_loads(reg, used_cfg, [:f, :g], unbound, unloaded, attempted_of((ID_X, :f))) == [LoadRequest(ID_X, :g, :g)]
    mixed = cfg_of(packages = Dict("Y" => Dict("bindings" => "used")))
    @test pending_loads(reg, mixed, [:f, :g, :h], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, :h)]
    sharing = registry_of([names_for(id, ["1.0.0"]; reexported = [:s], origin = ID_Z) for id in (ID_X, ID_Y)],
                          Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    @test isempty(pending_loads(sharing, all_cfg, [:s], unbound, unloaded, none))
    @test pending_loads(sharing, used_cfg, [:s], unbound, ==(ID_Y), none) == [LoadRequest(ID_Y, :s, :s)]
    @test pending_loads(sharing, all_cfg, [:s], unbound, Returns(true), none) == [LoadRequest(ID_X, :s, nothing)]
    # a package these requests load counts as loaded, whatever the order of the names
    owning = registry_of([names_for(ID_X, ["1.0.0"], [:f]; reexported = [:s], origin = ID_Z),
                          names_for(ID_Y, ["1.0.0"]; reexported = [:s], origin = ID_Z)], Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    @test pending_loads(owning, all_cfg, [:s, :f], unbound, unloaded, none) == [LoadRequest(ID_X, :f, nothing)]
    @test pending_loads(owning, used_cfg, [:s, :f], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, :f), LoadRequest(ID_X, :s, :s)]
end

@testset "to_index" begin
    cat = build_catalog([names_for(ID_X, ["1.0.0"]), failure_for(ID_Y, v"1.0.0"),
                         names_for(ID_Z, ["1.0.0"])])
    wanted = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(
        ID_X => v"1.0.0", ID_Y => v"1.0.0", ID_Z => v"2.0.0")
    @test to_index(cat, wanted) == [ID_Z]
    @test to_index(cat, Dict(ID_X => v"2.0.0", ID_Y => v"2.0.0")) == [ID_X, ID_Y]
    # version nothing: any record covers it
    @test isempty(to_index(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(ID_X => nothing)))
    @test to_index(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(pkg_id("W", 4) => nothing)) == [pkg_id("W", 4)]
end
