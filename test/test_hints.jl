# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module TestHints

using Test, REPL, Future, Autoloads

const Hints = Base.get_extension(Autoloads, :AutoloadsREPLExt)
pkg(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const A, B, C, D, E = pkg("A", 1), pkg("B", 2), pkg("C", 3), pkg("D", 4), pkg("E", 5)
const NO_ENV = id -> nothing

@testset "availability" begin
    deps, manifest, member = Set([A.uuid]), Set([A.uuid, B.uuid]), Set([A.uuid, C.uuid, E.uuid])
    on_path = id -> id == C ? "@v1.13" : nothing
    availability(id, deps = deps) = Hints.availability(id, deps, manifest, member, on_path)
    @test availability(A) == (Hints.DirectDep, nothing)
    @test availability(B) == (Hints.InProjectManifest, nothing)
    @test availability(C) == (Hints.OnLoadPath, "@v1.13")
    @test availability(E) == (Hints.AutoloadPackage, nothing)
    @test availability(D) == (Hints.Elsewhere, nothing)
    @test availability(A, Set{Base.UUID}()) == (Hints.InProjectManifest, nothing)
end

@testset "ranking" begin
    avail = Dict(A => (Hints.InProjectManifest, nothing), B => (Hints.DirectDep, nothing),
                 C => (Hints.Elsewhere, nothing), D => (Hints.Elsewhere, nothing),
                 E => (Hints.AutoloadPackage, nothing))
    ranked(ps) = [(p.id.name, p.owns) for p in Hints.rank_providers(ps, id -> avail[id])]
    @test ranked([(A, true), (B, false)]) == [("B", false), ("A", true)]
    @test ranked([(D, false), (C, true)]) == [("C", true), ("D", false)]
    @test ranked([(D, true), (C, true)]) == [("C", true), ("D", true)]
    @test ranked([(D, true), (E, false)]) == [("E", false), ("D", true)]
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
              Hints.RankedProvider(E, true, Hints.AutoloadPackage, nothing),
              Hints.RankedProvider(D, true, Hints.Elsewhere, nothing)]
    text = Hints.format_hint(:fa, ranked, Dict(A => ["B", "C"]), true)
    @test text == """

        Hint: fa is provided by packages that are not loaded:
            - `using A` (a dependency of the active project), which re-exports it from B and C
            - `pkg> add B` (already resolved in the active project's manifest)
            - `using C` (from @v1.13)
            - `using E` (an autoload package)
            - `pkg> add D`, or `pkg> autoloads add D`"""
    without_member = Hints.format_hint(:fa, ranked[5:5], Dict{Base.PkgId, Vector{String}}(), false)
    @test endswith(without_member, "- `pkg> add D` (run `pkg> autoloads init` to autoload packages)")
end

end
