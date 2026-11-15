module TestHints

using Test, REPL, Autoloads

const Hints = Base.get_extension(Autoloads, :AutoloadsREPLExt)
pkg(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const A, B, C, D = pkg("A", 1), pkg("B", 2), pkg("C", 3), pkg("D", 4)
const NO_ENV = id -> nothing

@testset "availability" begin
    deps, manifest = Set([A.uuid]), Set([A.uuid, B.uuid])
    on_path = id -> id == C ? "@v1.13" : nothing
    @test Hints.availability(A, deps, manifest, on_path) == (Hints.DirectDep, nothing)
    @test Hints.availability(B, deps, manifest, on_path) == (Hints.InProjectManifest, nothing)
    @test Hints.availability(C, deps, manifest, on_path) == (Hints.OnLoadPath, "@v1.13")
    @test Hints.availability(D, deps, manifest, on_path) == (Hints.Elsewhere, nothing)
    @test Hints.availability(A, Set{Base.UUID}(), manifest, on_path) == (Hints.InProjectManifest, nothing)
end

@testset "ranking" begin
    avail = Dict(A => (Hints.InProjectManifest, nothing), B => (Hints.DirectDep, nothing),
                 C => (Hints.Elsewhere, nothing), D => (Hints.Elsewhere, nothing))
    ranked(ps) = [(p.id.name, p.owns) for p in Hints.rank_providers(ps, id -> avail[id])]
    @test ranked([(A, true), (B, false)]) == [("B", false), ("A", true)]
    @test ranked([(D, false), (C, true)]) == [("C", true), ("D", false)]
    @test ranked([(D, true), (C, true)]) == [("C", true), ("D", true)]
    @test ranked([(A, true), (B, true), (C, true), (D, true)]) == [("B", true), ("A", true), ("C", true)]
    @test isempty(ranked([]))
end

@testset "re-export sources" begin
    graph = Autoloads.ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => nothing for id in (A, B, C)),
                                    Dict(A.uuid => [B.uuid], B.uuid => Base.UUID[], C.uuid => Base.UUID[]))
    providers = [(A, false), (B, true), (C, true)]
    @test Hints.reexport_sources(providers, graph) == Dict(A => ["B"])
    @test Hints.reexport_sources([(D, false), (B, true), (C, true)], graph) == Dict(D => ["B", "C"])
    @test Hints.reexport_sources([(B, false), (C, true)], graph) == Dict(B => ["C"])
end

@testset "hint text" begin
    ranked = [Hints.RankedProvider(A, false, Hints.DirectDep, nothing),
              Hints.RankedProvider(B, true, Hints.InProjectManifest, nothing),
              Hints.RankedProvider(C, true, Hints.OnLoadPath, "@v1.13"),
              Hints.RankedProvider(D, true, Hints.Elsewhere, nothing)]
    text = Hints.format_hint(:fa, ranked, Dict(A => ["B", "C"]), true)
    @test text == """

        Hint: fa is provided by packages that are not loaded:
            - `using A` (a dependency of the active project), which re-exports it from B and C
            - `pkg> add B` (already resolved in the active project's manifest)
            - `using C` (from @v1.13)
            - `pkg> add D`, or `pkg> autoloads add D`"""
    without_member = Hints.format_hint(:fa, ranked[4:4], Dict{Base.PkgId, Vector{String}}(), false)
    @test endswith(without_member, "- `pkg> add D` (run `pkg> autoloads init` to autoload packages)")
end

end
