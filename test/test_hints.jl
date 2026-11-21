# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module TestHints

using Test, REPL, Future, Autoloads

const Hints = Base.get_extension(Autoloads, :AutoloadsREPLExt)
pkg(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const A, B, C, D, E = pkg("A", 1), pkg("B", 2), pkg("C", 3), pkg("D", 4), pkg("E", 5)
const NO_ENV = id -> nothing

@testset "availability" begin
    graph(ids...) = Autoloads.ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => v"1.0.0" for id in ids),
                                            Dict{Base.UUID, Vector{Base.UUID}}(), Dict(id.uuid => id.name for id in ids))
    project, member = (; deps = [A], graph = graph(A, B)), (; deps = [A, C, E], graph = graph(A, C, E))
    onpath = id -> if id == C "@v1.13" end
    availability(id; project = project, newer = (id, installed) -> nothing) =
        Hints.availability(id, project, member, onpath, newer)
    @test availability(A) == (Hints.DirectDep, nothing, nothing)
    @test availability(B) == (Hints.InProjectManifest, nothing, nothing)
    @test availability(C) == (Hints.OnLoadPath, "@v1.13", nothing)
    @test availability(E) == (Hints.AutoloadPackage, nothing, nothing)
    @test availability(D) == (Hints.Elsewhere, nothing, nothing)
    @test availability(A; project = (; deps = Base.PkgId[], graph = graph(A, B))) == (Hints.InProjectManifest, nothing, nothing)
    @test availability(Base.PkgId(nothing, "Base.Threads")) == (Hints.Builtin, nothing, nothing)
    @testset "an installed version without the name" begin
        newer(id, installed) = if id in (A, B, C, E) v"2.0.0" end
        @test availability(A; newer) == (Hints.Outdated, nothing, v"1.0.0" => v"2.0.0")
        @test availability(B; newer) == (Hints.Outdated, nothing, v"1.0.0" => v"2.0.0")
        @test availability(C; newer) == (Hints.OnLoadPath, "@v1.13", nothing)
        @test availability(E; newer) == (Hints.OutdatedAutoload, nothing, v"1.0.0" => v"2.0.0")
    end
end

@testset "ranking" begin
    avail = Dict(A => (Hints.InProjectManifest, nothing, nothing), B => (Hints.DirectDep, nothing, nothing),
                 C => (Hints.Elsewhere, nothing, nothing), D => (Hints.Elsewhere, nothing, nothing),
                 E => (Hints.AutoloadPackage, nothing, nothing))
    ranked(ps) = [(p.id.name, p.owns) for p in Hints.rankproviders(ps, id -> avail[id])]
    @test ranked([(A, true), (B, false)]) == [("B", false), ("A", true)]
    @test ranked([(D, false), (C, true)]) == [("C", true), ("D", false)]
    @test ranked([(D, true), (C, true)]) == [("C", true), ("D", true)]
    @test ranked([(D, true), (E, false)]) == [("E", false), ("D", true)]
    @test ranked([(A, true), (B, true), (C, true), (D, true)]) == [("B", true), ("A", true), ("C", true)]
    @test isempty(ranked([]))
end

@testset "re-export sources" begin
    graph = Autoloads.ManifestGraph(Dict{Base.UUID, Union{VersionNumber, Nothing}}(id.uuid => nothing for id in (A, B, C)),
                                    Dict(A.uuid => [B.uuid], B.uuid => Base.UUID[], C.uuid => Base.UUID[]),
                                    Dict(id.uuid => id.name for id in (A, B, C)))
    providers = [(A, false), (B, true), (C, true)]
    @test Hints.reexportsources(providers, graph) == Dict(A => ["B"])
    @test Hints.reexportsources([(D, false), (B, true), (C, true)], graph) == Dict(D => ["B", "C"])
    @test Hints.reexportsources([(B, false), (C, true)], graph) == Dict(B => ["C"])
end

@testset "hint text" begin
    ranked = [Hints.RankedProvider(A, false, Hints.DirectDep, nothing, nothing),
              Hints.RankedProvider(B, true, Hints.InProjectManifest, nothing, nothing),
              Hints.RankedProvider(C, true, Hints.OnLoadPath, "@v1.13", nothing),
              Hints.RankedProvider(E, true, Hints.AutoloadPackage, nothing, nothing),
              Hints.RankedProvider(D, true, Hints.Elsewhere, nothing, nothing)]
    text = Hints.formathint(:fa, ranked, Dict(A => ["B", "C"]), true)
    @test String(text) == """

        Hint: fa is provided by packages that are not loaded:
          • using A  (a dependency of the active project, re-exports it from B and C)
          • pkg> add B  (already resolved in the active project's manifest)
          • using C  (from @v1.13)
          • using E  (an autoload package)
          • pkg> add D  (or pkg> autoloads add D)"""
    @test occursin("\e[36musing A\e[39m", sprint(print, text; context = :color => true))
    builtin = Hints.RankedProvider(Base.PkgId(nothing, "Base.Threads"), true, Hints.Builtin, nothing, nothing)
    @test endswith(Hints.formathint(:nthreads, [builtin], Dict{Base.PkgId, Vector{String}}(), true),
                   "• using Base.Threads  (part of Julia)")
    outdated = [Hints.RankedProvider(A, true, Hints.Outdated, nothing, v"1.0.0" => v"2.1.0"),
                Hints.RankedProvider(E, true, Hints.OutdatedAutoload, nothing, v"0.3.0" => v"0.4.0")]
    @test String(Hints.formathint(:fa, outdated, Dict{Base.PkgId, Vector{String}}(), true)) == """

        Hint: fa is provided by packages that are not loaded:
          • pkg> up A  (fa is in A v2.1.0; v1.0.0 is installed)
          • pkg> autoloads up E  (fa is in E v0.4.0; v0.3.0 is installed)"""
    withoutmember = Hints.formathint(:fa, ranked[5:5], Dict{Base.PkgId, Vector{String}}(), false)
    @test endswith(withoutmember, "• pkg> add D  (run pkg> autoloads init to autoload packages)")
end

end
