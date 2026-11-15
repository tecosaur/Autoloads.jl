using Test
using Random
using Autoloads: PkgNames, PkgFailure, CatalogRecord, extract_names,
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

names_record(versions, exported = Symbol[], public = Symbol[], reexported = Symbol[]) =
    PkgNames(ID_A, VersionNumber.(versions), Set(exported), Set(public), Set(reexported))

failure_record(version, message = "boom") = PkgFailure(ID_A, VersionNumber(version), message)

@testset "extract_names" begin
    r = extract_names(ExtractFixture)
    @test r.exported == Set([Symbol("@m"), :ExtractFixture, :Inner, :T, :f, :g, :x])
    @test r.public == Set([:p])
    @test r.reexported == Set([:base64encode])
    t = extract_names(Base.Threads, Base.PkgId(nothing, "Base.Threads"))
    @test Symbol("@spawn") in t.exported && :nthreads in t.exported && isempty(t.versions)
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
    @testset "versions stay sorted" begin
        merged = merge_observation(CatalogRecord[names_record(["2.0.0"], [:f])], a1)
        @test only(merged).versions == VersionNumber.(["1.0.0", "2.0.0"])
    end
    @testset "built-in (no version)" begin
        builtin = names_record(String[], [:f])
        @test merge_observation(CatalogRecord[builtin], builtin) == CatalogRecord[builtin]
        changed = names_record(String[], [:g])
        @test merge_observation(CatalogRecord[builtin], changed) == CatalogRecord[changed]
    end
end

# Small hand-rolled generator: no property-testing dependency.
random_symbols(rng) = Set(Symbol(rand(rng, ("f", "g", "@m", "T", "x1", "é", "a.b"))) for _ in 1:rand(rng, 0:4))

function random_versions(rng)
    pool = [v"0.1.0", v"1.0.0", v"1.2.3", v"2.0.0-rc1", v"3.0.0+build"]
    sort!(unique(rand(rng, pool, rand(rng, 0:3))))
end

function random_record(rng)
    id = Base.PkgId(Base.UUID(rand(rng, UInt128)), rand(rng, ("Foo", "Bar_baz", "Ünï")))
    if rand(rng, Bool)
        message = join(rand(rng, ("a", " ", "\t", "\n", "\\", "\\n", "\r", "end")), "") * "x"
        PkgFailure(id, rand(rng, Bool) ? rand(rng, [v"1.0.0", v"2.1.0-dev"]) : nothing, message)
    else
        PkgNames(id, random_versions(rng), random_symbols(rng), random_symbols(rng), random_symbols(rng))
    end
end

@testset "catalog line round-trip" begin
    rng = Random.MersenneTwister(42)
    @test all(1:100) do _
        r = random_record(rng)
        parse_catalog_line(catalog_line(r)) == r
    end
    @testset "format" begin
        line = catalog_line(names_record(["1.0.0", "2.0.0"], [:g, :f], [:p], Symbol[]))
        @test line == "$UUID_A\tA\t1.0.0,2.0.0\tok\tf g\tp\t"
        @test catalog_line(names_record(String[])) == "$UUID_A\tA\t-\tok\t\t\t"
        @test catalog_line(failure_record("1.0.0", "a\\b\nc")) == "$UUID_A\tA\t1.0.0\tfailed\ta\\\\b\\nc"
    end
    @testset "unwritable records are rejected" begin
        @test_throws ArgumentError catalog_line(names_record(["1.0.0"], [Symbol("a b")]))
        @test_throws ArgumentError catalog_line(PkgNames(Base.PkgId(UUID_A, "A B"), VersionNumber[], Set{Symbol}(), Set{Symbol}(), Set{Symbol}()))
    end
end

@testset "parse_catalog_line rejects malformed input" begin
    for line in (
        "",
        "garbage",
        "$UUID_A\tA\t1.0.0\tok\tf\tp",
        "$UUID_A\tA\t1.0.0\tok\tf\tp\tq\textra",
        "$UUID_A\tA\tnotaversion\tok\tf\tp\t",
        "$UUID_A\tA\t1.0.0\tmaybe\tf\tp\t",
        "$UUID_A\tA\t1.0.0\tfailed",
        "$UUID_A\tA\t1.0.0\tfailed\tbad\\escape",
        "$UUID_A\tA\t1.0.0\tfailed\ttrailing\\",
        "not-a-uuid\tA\t1.0.0\tok\tf\tp\t",
        "\tA\t1.0.0\tok\tf\tp\t",
        "$UUID_A\t\t1.0.0\tok\tf\tp\t",
    )
        @test parse_catalog_line(line) === nothing
    end
end
