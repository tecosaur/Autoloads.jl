# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test
using Random
using Autoloads: PkgNames, PkgFailure, CatalogRecord, Sighting, JULIA_MINOR, sighting_order, extract_names,
    merge_observation, catalog_line, parse_catalog_line

module ExtractFixture
    module Inner; export g; g() = 1; end
    using .Inner, Base64
    export f, T, x, @m, g, Inner, sum, base64encode
    public p
    f() = 1; struct T end; const x = 1; macro m() end; p() = 2
end

const UUID_A = Base.UUID("11111111-2222-3333-4444-555555555555")
const ID_A = Base.PkgId(UUID_A, "A")

const J = "$(JULIA_MINOR.major).$(JULIA_MINOR.minor)"

"Sightings of `versions` (strings, or `nothing` for none) on Julia minor `julia`."
sightings(versions, julia = JULIA_MINOR) =
    Sighting[(; version = if v === nothing nothing else VersionNumber(v) end, julia) for v in versions]

names_record(versions, exported = Symbol[], public = Symbol[], reexported = Symbol[]; julia = JULIA_MINOR) =
    PkgNames(ID_A, sightings(versions, julia), Set(exported), Set(public), Set(reexported))

failure_record(version, message = "boom"; julia = JULIA_MINOR) =
    PkgFailure(ID_A, sightings([version], julia), message)

@testset "extract_names" begin
    r = extract_names(ExtractFixture)
    @test r.exported == Set([Symbol("@m"), :ExtractFixture, :Inner, :T, :f, :g, :x])
    @test r.public == Set([:p])
    @test r.reexported == Set([:base64encode])
    @test r.kinds == Dict(:ExtractFixture => '.', :Inner => '.', :f => '+', :g => '+', :p => '+', :base64encode => '+',
                          :T => ':', :x => '=')
    @test r.origins == Dict(:base64encode => Base.PkgId(ExtractFixture.Base64))
    t = extract_names(Base.Threads, Base.PkgId(nothing, "Base.Threads"))
    @test Symbol("@spawn") in t.exported && :nthreads in t.exported && t.at == sightings([nothing])
    @test :Threads in t.exported
end

@testset "merge_observation" begin
    a1 = names_record(["1.0.0"], [:f])
    a2 = names_record(["2.0.0"], [:f])
    b2 = names_record(["2.0.0"], [:f, :g])
    @testset "identical namespace joins versions" begin
        merged = merge_observation(CatalogRecord[a1], a2)
        @test merged == CatalogRecord[names_record(["1.0.0", "2.0.0"], [:f])]
    end
    @testset "different namespace adds record" begin
        merged = merge_observation(CatalogRecord[a1], b2)
        @test merged == CatalogRecord[a1, b2]
    end
    @testset "changed names at recorded version moves it" begin
        both = names_record(["1.0.0", "2.0.0"], [:f])
        merged = merge_observation(CatalogRecord[both], names_record(["2.0.0"], [:f, :g]))
        @test merged == CatalogRecord[names_record(["1.0.0"], [:f]), b2]
        merged = merge_observation(CatalogRecord[a1], names_record(["1.0.0"], [:g]))
        @test merged == CatalogRecord[names_record(["1.0.0"], [:g])]
    end
    @testset "success replaces failure" begin
        merged = merge_observation(CatalogRecord[a1, failure_record("2.0.0")], a2)
        @test merged == CatalogRecord[names_record(["1.0.0", "2.0.0"], [:f])]
    end
    @testset "failure replaces success" begin
        merged = merge_observation(CatalogRecord[names_record(["1.0.0", "2.0.0"], [:f])], failure_record("2.0.0"))
        @test merged == CatalogRecord[a1, failure_record("2.0.0")]
    end
    @testset "multi-version observation folds per version" begin
        multi = names_record(["1.0.0", "2.0.0"], [:g])
        merged = merge_observation(CatalogRecord[a1, failure_record("2.0.0")], multi)
        @test merged == foldl(merge_observation, [names_record(["1.0.0"], [:g]), names_record(["2.0.0"], [:g])];
                              init = CatalogRecord[a1, failure_record("2.0.0")])
        @test merged == CatalogRecord[names_record(["1.0.0", "2.0.0"], [:g])]
        @test merge_observation(CatalogRecord[], multi) == CatalogRecord[multi]
    end
    @testset "repeated observation is unchanged" begin
        existing = CatalogRecord[a1, failure_record("2.0.0")]
        @test merge_observation(existing, a1) == existing
        @test merge_observation(existing, failure_record("2.0.0")) == existing
    end
    @testset "sightings stay sorted" begin
        merged = merge_observation(CatalogRecord[names_record(["2.0.0"], [:f])], a1)
        @test only(merged).at == sightings(["1.0.0", "2.0.0"])
        later = names_record(["1.0.0"], [:f]; julia = v"99.0")
        @test only(merge_observation(CatalogRecord[later], a2)).at == [sightings(["2.0.0"]); sightings(["1.0.0"], v"99.0")]
    end
    @testset "built-in (no version)" begin
        builtin = names_record([nothing], [:f])
        @test merge_observation(CatalogRecord[builtin], builtin) == CatalogRecord[builtin]
        changed = names_record([nothing], [:g])
        @test merge_observation(CatalogRecord[builtin], changed) == CatalogRecord[changed]
    end
    @testset "Julia minors are kept apart" begin
        other = names_record(["1.0.0"], [:f]; julia = v"1.0")
        both = PkgNames(ID_A, [sightings(["1.0.0"], v"1.0"); sightings(["1.0.0"])], Set([:f]), Set{Symbol}(), Set{Symbol}())
        @test merge_observation(CatalogRecord[a1], other) == CatalogRecord[both]
        changed = names_record(["1.0.0"], [:g]; julia = v"1.0")
        @test merge_observation(CatalogRecord[a1], changed) == CatalogRecord[a1, changed]
        failed = failure_record("1.0.0"; julia = v"1.0")
        @test merge_observation(CatalogRecord[a1], failed) == CatalogRecord[a1, failed]
        @test merge_observation(CatalogRecord[failed], a1) == CatalogRecord[failed, a1]
        @test merge_observation(CatalogRecord[failed], failure_record("1.0.0")) ==
              CatalogRecord[PkgFailure(ID_A, [sightings(["1.0.0"], v"1.0"); sightings(["1.0.0"])], "boom")]
    end
end

# Small hand-rolled generator: no property-testing dependency.
random_symbols(rng) = Set(Symbol(rand(rng, ("f", "g", "@m", "T", "x1", "é", "a.b"))) for _ in 1:rand(rng, 0:4))

const VERSION_POOL = [nothing, v"0.1.0", v"1.0.0", v"1.2.3", v"2.0.0-rc1", v"3.0.0+build"]
const JULIA_POOL = [v"1.9", v"1.10", v"1.11", v"1.13", v"2.0"]

random_sighting(rng) = Sighting((rand(rng, VERSION_POOL), rand(rng, JULIA_POOL)))

random_sightings(rng) = sort!(unique([random_sighting(rng) for _ in 1:rand(rng, 1:8)]); by = sighting_order)

function random_record(rng)
    id = Base.PkgId(Base.UUID(rand(rng, UInt128)), rand(rng, ("Foo", "Bar_baz", "Ünï")))
    if rand(rng, Bool)
        message = join(rand(rng, ("a", " ", "\t", "\n", "\\", "\\n", "\r", "end")), "") * "x"
        PkgFailure(id, random_sightings(rng), message)
    else
        sets = (random_symbols(rng), random_symbols(rng), random_symbols(rng))
        kinds = Dict{Symbol, Char}(name => rand(rng, ".+:=") for names in sets for name in names
                                   if rand(rng, Bool) && !startswith(String(name), '@'))
        origins = Dict{Symbol, Base.PkgId}(name => Base.PkgId(rand(rng, (nothing, UUID_A)), rand(rng, ("Base", "Origin")))
                                           for name in sets[3] if rand(rng, Bool))
        PkgNames(id, random_sightings(rng), sets...; kinds, origins)
    end
end

@testset "merging several sightings at once equals one at a time" begin
    rng = Random.MersenneTwister(7)
    namespaces = [Set([:A, :f]), Set([:A, :g]), Set([:A])]
    random_names(rng) = PkgNames(ID_A, random_sightings(rng), rand(rng, namespaces), Set{Symbol}(), Set{Symbol}())
    random_observation(rng) = if rand(rng, Bool) random_names(rng) else PkgFailure(ID_A, [random_sighting(rng)], "boom") end
    @test all(1:500) do _
        existing = foldl(merge_observation, [random_observation(rng) for _ in 1:rand(rng, 0:4)]; init = CatalogRecord[])
        new = random_names(rng)
        merge_observation(existing, new) == foldl(new.at; init = existing) do records, sighting
            merge_observation(records, PkgNames(ID_A, [sighting], new.exported, new.public, new.reexported))
        end
    end
end

@testset "catalog line round-trip" begin
    rng = Random.MersenneTwister(42)
    @test all(1:300) do _
        r = random_record(rng)
        parse_catalog_line(catalog_line(r)) == r
    end
    @testset "format" begin
        line = catalog_line(names_record(["1.0.0", "2.0.0"], [:g, :f], [:p], Symbol[]))
        @test line == "$UUID_A\tA\t1.0.0,2.0.0@$J\tok\t?f ?g\t?p\t"
        kinded = PkgNames(ID_A, sightings(["1.0.0"]), Set([:A, :f, Symbol("@m")]), Set([:T]), Set([:x, :y, :z]);
                          kinds = Dict(:A => '.', :f => '+', :T => ':', :x => '='),
                          origins = Dict(:y => Base.PkgId(UUID_A, "Origin"), :z => Base.PkgId(nothing, "Base")))
        @test catalog_line(kinded) == "$UUID_A\tA\t1.0.0@$J\tok\t@m .A +f\t:T\t=x //Base ?z /$UUID_A/Origin ?y"
        @test catalog_line(names_record([nothing])) == "$UUID_A\tA\t-@$J\tok\t\t\t"
        @test catalog_line(failure_record("1.0.0", "a\\b\nc")) == "$UUID_A\tA\t1.0.0@$J\tfailed\ta\\\\b\\nc"
    end
    @testset "sightings group by their Julia minors, in ranges" begin
        at = [sightings(["1.0.0", "1.1.0", nothing], v"1.10"); sightings(["1.0.0", "1.1.0"], v"1.11");
              sightings(["1.0.0", "1.1.0", "1.2.0"], v"1.12"); sightings(["1.2.0"], v"1.14")]
        line = catalog_line(PkgNames(ID_A, sort!(at; by = sighting_order), Set([:A]), Set{Symbol}(), Set{Symbol}()))
        @test split(line, '\t')[3] == "-@1.10;1.0.0,1.1.0@1.10-12;1.2.0@1.12+1.14"
    end
    @testset "unwritable records are rejected" begin
        @test_throws ArgumentError catalog_line(names_record(["1.0.0"], [Symbol("a b")]))
        @test_throws ArgumentError catalog_line(PkgNames(Base.PkgId(UUID_A, "A B"), sightings([nothing]), Set{Symbol}(), Set{Symbol}(), Set{Symbol}()))
    end
end

@testset "parse_catalog_line rejects malformed input" begin
    for line in (
        "",
        "garbage",
        "$UUID_A\tA\t1.0.0@$J\tok\t+f\t?p",
        "$UUID_A\tA\t1.0.0@$J\tok\t+f\t?p\tq\textra",
        "$UUID_A\tA\tnotaversion@$J\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0\tok\t+f\t?p\t",
        "$UUID_A\tA\t@$J\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12.0\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@v1.12\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.14-12\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12-1.14\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12-13-14\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12+\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.123456\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12@1.13\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@1.12;\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@$J\tmaybe\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@$J\tfailed",
        "$UUID_A\tA\t1.0.0@$J\tfailed\tbad\\escape",
        "$UUID_A\tA\t1.0.0@$J\tfailed\ttrailing\\",
        "not-a-uuid\tA\t1.0.0@$J\tok\t+f\t?p\t",
        "\tA\t1.0.0@$J\tok\t+f\t?p\t",
        "$UUID_A\t\t1.0.0@$J\tok\t+f\t?p\t",
        "$UUID_A\tA\t1.0.0@$J\tok\tf g\tp\t",
        "$UUID_A\tA\t1.0.0@$J\tok\tff\t?p\t",
        "$UUID_A\tA\t1.0.0@$J\tok\t+f\t?\t",
        "$UUID_A\tA\t1.0.0@$J\tok\t+f\t?p\t/Origin +g",
        "$UUID_A\tA\t1.0.0@$J\tok\t+f\t?p\t/not-a-uuid/Origin +g",
    )
        @test parse_catalog_line(line) === nothing
    end
end
