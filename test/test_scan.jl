# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test, Random, REPL, Future, Autoloads
using Autoloads: PkgNames, buildcatalog, buildregistry, parseconfig

const Scan = Base.get_extension(Autoloads, :AutoloadsREPLExt)

replinput(s) = REPL.softscope(Base.parse_input_line(s))
statementsof(ex) = (out = Any[]; Scan.mapstatements(st -> (push!(out, st); st), ex); out)

function scanregistry()
    at = Autoloads.Sighting[(; version = v"1.0.0", julia = Autoloads.JULIA_MINOR)]
    pkg(name, n, exported) = PkgNames(Base.PkgId(Base.UUID(UInt128(n)), name), at, Set([Symbol(name); exported]),
                                      Set{Symbol}(), Set{Symbol}())
    records = [pkg("DataFrames", 1, [:DataFrame]), pkg("BenchmarkTools", 2, [Symbol("@btime")]),
               pkg("Profile", 3, Symbol[])]
    autoload = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(r.id => v"1.0.0" for r in records)
    buildregistry(buildcatalog(records), autoload, parseconfig(Dict{String, Any}()))
end

@testset "scanning" begin
    reg = scanregistry()
    memberonly = name -> name === :FixtureA
    candidate(s) = Scan.iscandidatestatement(reg, s, memberonly)
    marks(s) = map(candidate, statementsof(replinput(s)))
    @test marks("x = 1; DataFrame(x)") == [false, true]
    @test marks("@btime f(x)") == [true]
    @test marks("quote DataFrame end") == [false]
    @test marks("quote \$DataFrame end") == [true]
    @test marks(":(f(\$(:DataFrame)))") == [false]
    @test marks("using FixtureA") == [true]
    @test marks("using .FixtureA") == [false]
    @test marks("using Other") == [false]
    @test marks("import Other as FixtureA") == [false]
    @test marks("import FixtureA: x as y") == [true]
    @test marks("using DataFrames") == [true]
    timed = only(statementsof(replinput("@time using FixtureA")))
    @test candidate(timed)
    importsmemberonly(stmt) = Scan.anyunquoted(node -> Scan.ismemberonlyimport(node, memberonly), stmt)
    @test importsmemberonly(timed)
    @test !importsmemberonly(:(using Other))
    @test !importsmemberonly(:(:(using FixtureA)))
    @test Scan.statementmacros(:(Profile.Allocs.@profile g())) == [:Profile]
    @test Scan.statementmacros(:(@btime f(@time x))) == [Symbol("@btime"), Symbol("@time")]
    @test isempty(Scan.statementmacros(:(quote @btime f() end)))
end

@testset "statement mapping" begin
    input = replinput("x = 1; y = 2\nf(z)")
    seen = statementsof(input)
    @test Scan.mapstatements(identity, input) == input
    @test length(seen) == 3 && all(st -> Meta.isexpr(st, :block) && Expr(:softscope, true) in st.args, seen)
    @test Scan.mapstatements(st -> :replaced, Expr(:toplevel, LineNumberNode(1), :a, Expr(:toplevel, :b))) ==
        Expr(:toplevel, LineNumberNode(1), :replaced, Expr(:toplevel, :replaced))
    @test Scan.mapstatements(st -> :replaced, :(f(x))) === :replaced
    @test Scan.mapstatements(identity, replinput("using A")) == replinput("using A")
end

@testset "undefined globals" begin
    refs(s) = sort!(Scan.undefinedglobals(Meta.parse(s), Module()))
    @test refs("DataFrame(x)") == [:DataFrame, :x]
    @test refs("Dates.now()") == [:Dates]
    @test refs("x -> DataFrame(x)") == [:DataFrame]
    @test refs("let DataFrame = 1; DataFrame + q end") == [:q]
    @test refs("[f(i) for i in xs]") == [:f, :xs]
    @test refs("(mad = \"sane\",)") == []
    @test refs("mad = \"sane\"") == []
    @test refs("f(about) = about + 1") == []
    @test refs("function h(x; DataFrame=1) DataFrame end") == []
    @test refs("for Dates in 1:3; Dates; end") == []
    @test refs("StatsBase.mad(a::MyType) = 1") == [:MyType, :StatsBase]
    @test refs("g() = DataFrame()") == [:DataFrame]
    @test refs("(a, DataFrame) = (1, 2)") == []
    @test refs("try error() catch DataFrame; DataFrame end") == []
    @test refs("struct S{T} <: AbstractVector{T} end") == []
    @test refs("@eval DataFrame()") == []        # pinned non-goal
    # declarations, defined names, REPL-shaped input and lowering failures
    @test refs("global q") == []
    @test refs("const z = DataFrame") == [:DataFrame]
    @test refs("println(x)") == [:x]
    @test refs("@undefined_macro x") == []
    mod = Module()
    Core.eval(mod, :(DataFrame = 1))
    @test Scan.undefinedglobals(:(DataFrame + q), mod) == [:q]
    @test sort!(Scan.undefinedglobals(only(statementsof(replinput("for i in xs; total = f(i); end"))), Module())) == [:f, :xs]
    @test Scan.undefinedglobals(only(statementsof(replinput("DataFrame"))), Module()) == [:DataFrame]
    @test isempty(Scan.undefinedglobals(only(statementsof(replinput("DataFrame"))), mod))
end

@testset "help queries" begin
    reg = scanregistry()
    helpstatement(s) = only(statementsof(REPL.softscope(REPL.helpmode(devnull, s, Main))))
    queried(s) = Scan.helpquerynames(helpstatement(s))
    @test queried("DataFrame") == [:DataFrame]
    @test queried("?DataFrame") == [:DataFrame]
    @test queried("DataFrames.DataFrame(x, x)") == [:DataFrames, :x]
    @test queried("@btime") == [Symbol("@btime")]
    @test queried("Profile.@profile") == [:Profile]
    @test isempty(queried("\"DataFrame\""))
    @test isempty(queried(":(DataFrame)"))
    @test Scan.iscandidatestatement(reg, helpstatement("DataFrame"), Returns(false))
    @test !Scan.iscandidatestatement(reg, helpstatement("sum"), Returns(false))
    for input in ("DataFrame", "DataFrame(x)", "@btime f()", "using DataFrames")
        @test Scan.helpquerynames(only(statementsof(replinput(input)))) === nothing
    end
end

"""
Random expression over `pool` built from binding forms, with its free names
(those a correct resolver may report) and the names it binds.
"""
function bindingform(rng, depth, pool = (:a, :b, :DataFrame))
    depth == 0 && (name = rand(rng, pool); return (name, Set([name]), Set{Symbol}()))
    kind = rand(rng, 1:7)
    kind == 1 && return bindingform(rng, 0, pool)
    if kind == 2
        (x, fx, bx), (y, fy, by) = bindingform(rng, depth - 1, pool), bindingform(rng, depth - 1, pool)
        return (Expr(:tuple, x, y), fx ∪ fy, bx ∪ by)
    end
    var = rand(rng, pool)
    body, free, bound = bindingform(rng, depth - 1, pool)
    ex = kind == 3 ? :(let $var = 1; $body end) :
         kind == 4 ? :($var -> $body) :
         kind == 5 ? :(for $var in 1:2; $body; end) :
         kind == 6 ? :([$body for $var in 1:2]) :
                     :(try error() catch $var; $body end)
    (ex, setdiff(free, [var]), bound ∪ [var])
end

@testset "undefined globals: binding-form property" begin
    rng = Xoshiro(0x5ca9)
    for _ in 1:200
        ex, free, bound = bindingform(rng, rand(rng, 1:4))
        rand(rng, Bool) && (target = rand(rng, (:a, :b, :DataFrame)); ex = :($target = $ex); bound = bound ∪ [target])
        found = Scan.undefinedglobals(ex, Module())
        @test found ⊆ free
        @test isempty(intersect(found, setdiff(bound, free)))
    end
end
