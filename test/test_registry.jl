# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Sighting, JULIA_MINOR, Config, PackageConfig, parseconfig,
    ManifestGraph, AllBindings, UsedBindings, Catalog, Registry, LoadRequest, buildcatalog,
    recordsof, namesat, failedat, providers, autoloadset, buildregistry, owner,
    iscandidate, pendingloads, unindexed, builtinrecords

pkgid(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const ID_X, ID_Y, ID_Z = pkgid("X", 1), pkgid("Y", 2), pkgid("Z", 3)

namesfor(id, versions, exported = Symbol[]; public = Symbol[], reexported = Symbol[], origin = nothing,
          julia = JULIA_MINOR) =
    PkgNames(id, Sighting[(; version = VersionNumber(v), julia) for v in versions], Set([Symbol(id.name); exported]),
             Set(public), Set(reexported);
             origins = Dict{Symbol, Base.PkgId}(name => origin for name in reexported if origin !== nothing))

failurefor(id, version; julia = JULIA_MINOR) = PkgFailure(id, Sighting[(; version, julia)], "boom")

# Neither stdlibs nor the project autoload unless a test asks.
cfgof(; kwargs...) = parseconfig(Dict{String, Any}("stdlib" => false, "project" => false,
                                                     (string(k) => v for (k, v) in kwargs)...))
nograph = ManifestGraph()
graphof(pairs...) = ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => v for (id, v) in pairs),
                                   Dict{Base.UUID, Vector{Base.UUID}}(), Dict(id.uuid => id.name for (id, _) in pairs))
registryof(records, autoload, cfg = cfgof()) = buildregistry(buildcatalog(records), autoload, cfg)

@testset "catalog" begin
    a1 = namesfor(ID_X, ["1.0.0", "1.1.0"], [:f])
    a2 = namesfor(ID_X, ["2.0.0"], [:f, :g])
    cat = buildcatalog([a1, a2, failurefor(ID_Y, v"1.0.0")])
    @test namesat(cat, ID_X, v"1.1.0").at == Sighting[(; version, julia = JULIA_MINOR) for version in (v"1.0.0", v"1.1.0")]
    @test namesat(cat, ID_X, v"2.0.0") == a2
    @test namesat(cat, ID_X, v"3.0.0") === nothing
    @test namesat(cat, ID_X, nothing) == a2
    @test namesat(cat, ID_Z, nothing) === nothing
    @test length(recordsof(cat, ID_X)) == 2
    @test isempty(recordsof(cat, ID_Z))
    @test failedat(cat, ID_Y, v"1.0.0").message == "boom"
    @test failedat(cat, ID_Y, v"2.0.0") === nothing
    builtin = only(filter(r -> r.id.name == "Base.Threads", builtinrecords()))
    @test namesat(buildcatalog([builtin]), builtin.id, nothing) == builtin
    # newest record provides; providers sorted by package name; owns flag
    other = namesfor(ID_Y, ["1.0.0"], Symbol[]; reexported = [:f])
    pc = buildcatalog([a1, a2, other])
    @test providers(pc, :g) == [(ID_X, true)]
    @test providers(pc, :f) == [(ID_X, true), (ID_Y, false)]
    @test isempty(providers(pc, :nope))
    @test isempty(providers(buildcatalog([namesfor(ID_X, ["1.0.0"]; public = [:p])]), :p))
end

@testset "lookups from another Julia minor" begin
    older = namesfor(ID_X, ["1.0.0"], [:old]; julia = v"1.11")
    near = namesfor(ID_X, ["1.0.0"], [:near]; julia = v"1.12")
    newer = namesfor(ID_X, ["1.0.0"], [:new]; julia = v"1.14")
    from(julia, records...) = buildcatalog(collect(CatalogRecord, records); julia)
    @test namesat(from(v"1.12", older, near, newer), ID_X, v"1.0.0") == near
    @test namesat(from(v"1.13", older, near, newer), ID_X, v"1.0.0") == near
    @test namesat(from(v"1.13", older, newer), ID_X, v"1.0.0") == older
    @test namesat(from(v"1.13", newer), ID_X, v"1.0.0") == newer
    major = namesfor(ID_X, ["1.0.0"], [:major]; julia = v"2.0")
    pastmajor = namesfor(ID_X, ["1.0.0"], [:pastmajor]; julia = v"2.1")
    @test namesat(from(v"1.13", pastmajor, major), ID_X, v"1.0.0") == major
    @test namesat(from(v"1.13", near), ID_X, v"2.0.0") === nothing
    @test providers(from(v"1.13", older, newer), :old) == [(ID_X, true)]
    # This minor's records come first, whatever the version.
    here = namesfor(ID_X, ["1.0.0"], [:here]; julia = v"1.13")
    later = namesfor(ID_X, ["2.0.0"], [:later]; julia = v"1.12")
    @test namesat(from(v"1.13", here, later), ID_X, nothing) == here
    @testset "a stand-in is still indexed, and failures stay with their minor" begin
        cat = from(v"1.13", near, failurefor(ID_Y, v"1.0.0"; julia = v"1.12"))
        @test failedat(cat, ID_Y, v"1.0.0") === nothing
        @test unindexed(cat, Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0")) == [ID_X, ID_Y]
        @test unindexed(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(ID_X => nothing)) == [ID_X]
    end
end

@testset "autoload_set" begin
    member = graphof(ID_X => v"1.0.0")
    proj = graphof(ID_X => v"2.0.0", ID_Y => v"1.0.0", ID_Z => nothing)
    stdlib = pkgid("Std", 9)
    builtin = Base.PkgId(nothing, "Base.Threads")
    run(cfg) = autoloadset([ID_X], member, [ID_X, ID_Y, ID_Z], proj, [stdlib], [builtin], cfg)
    @test run(cfgof()) == Dict(ID_X => v"1.0.0")
    @test run(cfgof(project = true)) == Dict(ID_X => v"2.0.0", ID_Y => v"1.0.0", ID_Z => nothing)
    @test run(cfgof(project = ["Y"])) == Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0")
    @test run(cfgof(project = ["X"])) == Dict(ID_X => v"2.0.0")
    @test run(cfgof(project = String[])) == Dict(ID_X => v"1.0.0")
    @test run(cfgof(stdlib = true)) == Dict(ID_X => v"1.0.0", stdlib => nothing, builtin => nothing)
    @test autoloadset(Base.PkgId[], nograph, Base.PkgId[], graphof(stdlib => v"1.2.3"), [stdlib], Base.PkgId[],
                       cfgof(stdlib = true)) == Dict(stdlib => v"1.2.3")
end

@testset "build_registry" begin
    auto(ids...) = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => nothing for id in ids)
    reg = registryof([namesfor(ID_X, ["1.0.0"], [:f]; public = [:p])], auto(ID_X))
    @test owner(reg, :f) == ID_X && owner(reg, :X) == ID_X
    @test !iscandidate(reg, :p) && owner(reg, :p) === nothing
    # owner beats re-exporter in both orders
    own = namesfor(ID_X, ["1.0.0"], [:f]); re = namesfor(ID_Y, ["1.0.0"]; reexported = [:f])
    for records in ([own, re], [re, own])
        r = registryof(records, auto(ID_X, ID_Y))
        @test owner(r, :f) == ID_X && isempty(r.ambiguous)
    end
    # two owners, and two re-exporters with no owner, are ambiguous
    r = registryof([own, namesfor(ID_Y, ["1.0.0"], [:f])], auto(ID_X, ID_Y))
    @test !iscandidate(r, :f) && r.ambiguous[:f] == [ID_X, ID_Y]
    r = registryof([namesfor(ID_X, ["1.0.0"]; reexported = [:f]), re], auto(ID_X, ID_Y))
    @test sort(r.ambiguous[:f]; by = i -> i.name) == [ID_X, ID_Y]
    r = registryof([namesfor(ID_X, ["1.0.0"]; reexported = [:f])], auto(ID_X))
    @test owner(r, :f) == ID_X
    # re-exporters of one known origin share the name, unless the origin autoloads too
    from(id, origin) = namesfor(id, ["1.0.0"]; reexported = [:f], origin)
    r = registryof([from(ID_X, ID_Z), from(ID_Y, ID_Z)], auto(ID_X, ID_Y))
    @test r.shared[:f] == [ID_X, ID_Y] && iscandidate(r, :f) && owner(r, :f) === nothing && isempty(r.ambiguous)
    r = registryof([from(ID_X, ID_Z), from(ID_Y, ID_Z), namesfor(ID_Z, ["1.0.0"], [:f])], auto(ID_X, ID_Y, ID_Z))
    @test owner(r, :f) == ID_Z && isempty(r.shared)
    for other in (ID_X, nothing)
        r = registryof([from(ID_X, ID_Z), from(ID_Y, other)], auto(ID_X, ID_Y))
        @test haskey(r.ambiguous, :f) && isempty(r.shared)
    end
    # version selection: exact record, else newest
    recs = [namesfor(ID_X, ["1.0.0"], [:old]), namesfor(ID_X, ["2.0.0"], [:new])]
    @test owner(registryof(recs, Dict(ID_X => v"1.0.0")), :old) == ID_X
    @test owner(registryof(recs, Dict(ID_X => v"3.0.0")), :new) == ID_X
    @test !iscandidate(registryof(recs, Dict(ID_X => v"1.0.0")), :new)
    @test !iscandidate(registryof(Any[], auto(ID_X)), :X)
    # skip / only
    skip = cfgof(packages = Dict("X" => Dict("skip" => ["f"])))
    @test !iscandidate(registryof([own], auto(ID_X), skip), :f)
    onlycfg = cfgof(packages = Dict("X" => Dict("only" => ["g"])))
    r = registryof([namesfor(ID_X, ["1.0.0"], [:f, :g])], auto(ID_X), onlycfg)
    @test iscandidate(r, :g) && !iscandidate(r, :f) && iscandidate(r, :X)
    # stdlib overrides use the same packages table
    dist = pkgid("Distributed", 7)
    spawn = Symbol("@spawn")
    threads = only(filter(r -> r.id.name == "Base.Threads", builtinrecords()))
    records = [namesfor(dist, ["1.0.0"], [spawn]), threads]
    wanted = auto(dist, threads.id)
    r = registryof(records, wanted)
    @test haskey(r.ambiguous, spawn)
    r = registryof(records, wanted, cfgof(packages = Dict("Distributed" => Dict("skip" => ["@spawn"]))))
    @test owner(r, spawn) == threads.id
end

@testset "pending_loads" begin
    reg = registryof([namesfor(ID_X, ["1.0.0"], [:f, :g]), namesfor(ID_Y, ["1.0.0"], [:h])],
                      Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    none = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}()
    unbound = unloaded = Returns(false)
    attemptedof(pairs...) = Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(pairs)
    allcfg = cfgof()
    usedcfg = cfgof(bindings = "used")
    @test pendingloads(reg, allcfg, [:f, :g, :h, :zzz], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, nothing)]
    @test pendingloads(reg, usedcfg, [:f, :g, :zzz], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, :f), LoadRequest(ID_X, :g, :g)]
    @test pendingloads(reg, usedcfg, [:f, :g], ==(:f), unloaded, none) == [LoadRequest(ID_X, :g, :g)]
    @test isempty(pendingloads(reg, allcfg, [:f], unbound, unloaded, attemptedof((ID_X, nothing))))
    @test pendingloads(reg, usedcfg, [:f, :g], unbound, unloaded, attemptedof((ID_X, :f))) == [LoadRequest(ID_X, :g, :g)]
    mixed = cfgof(packages = Dict("Y" => Dict("bindings" => "used")))
    @test pendingloads(reg, mixed, [:f, :g, :h], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, nothing), LoadRequest(ID_Y, :h, :h)]
    sharing = registryof([namesfor(id, ["1.0.0"]; reexported = [:s], origin = ID_Z) for id in (ID_X, ID_Y)],
                          Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    @test isempty(pendingloads(sharing, allcfg, [:s], unbound, unloaded, none))
    @test pendingloads(sharing, usedcfg, [:s], unbound, ==(ID_Y), none) == [LoadRequest(ID_Y, :s, :s)]
    @test pendingloads(sharing, allcfg, [:s], unbound, Returns(true), none) == [LoadRequest(ID_X, :s, nothing)]
    # a package these requests load counts as loaded, whatever the order of the names
    owning = registryof([namesfor(ID_X, ["1.0.0"], [:f]; reexported = [:s], origin = ID_Z),
                          namesfor(ID_Y, ["1.0.0"]; reexported = [:s], origin = ID_Z)], Dict(ID_X => v"1.0.0", ID_Y => v"1.0.0"))
    @test pendingloads(owning, allcfg, [:s, :f], unbound, unloaded, none) == [LoadRequest(ID_X, :f, nothing)]
    @test pendingloads(owning, usedcfg, [:s, :f], unbound, unloaded, none) ==
          [LoadRequest(ID_X, :f, :f), LoadRequest(ID_X, :s, :s)]
end

@testset "to_index" begin
    cat = buildcatalog([namesfor(ID_X, ["1.0.0"]), failurefor(ID_Y, v"1.0.0"),
                         namesfor(ID_Z, ["1.0.0"])])
    wanted = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(
        ID_X => v"1.0.0", ID_Y => v"1.0.0", ID_Z => v"2.0.0")
    @test unindexed(cat, wanted) == [ID_Z]
    @test unindexed(cat, Dict(ID_X => v"2.0.0", ID_Y => v"2.0.0")) == [ID_X, ID_Y]
    # version nothing: any record covers it
    @test isempty(unindexed(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(ID_X => nothing)))
    @test unindexed(cat, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(pkgid("W", 4) => nothing)) == [pkgid("W", 4)]
end
