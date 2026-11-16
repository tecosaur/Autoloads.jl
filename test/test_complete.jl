# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module TestComplete

using Test, REPL, Future, Autoloads
using REPL.LineEdit: LineEdit, NamedCompletion

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
pkg(name, n) = Base.PkgId(Base.UUID(UInt128(n)), name)
const DATAFRAMES, BENCHMARKTOOLS, OTHER = pkg("DataFrames", 1), pkg("BenchmarkTools", 2), pkg("Other", 3)

const CATALOG = Autoloads.build_catalog([
    Autoloads.PkgNames(DATAFRAMES, [v"1.0.0"], Set([:DataFrames, :DataFrame, :groupby, :shared]), Set([:metadata]), Set{Symbol}()),
    Autoloads.PkgNames(BENCHMARKTOOLS, [v"1.0.0"], Set([:BenchmarkTools, Symbol("@btime")]), Set{Symbol}(), Set{Symbol}()),
    Autoloads.PkgNames(OTHER, [v"1.0.0"], Set([:Other, :shared]), Set{Symbol}(), Set{Symbol}())])
const CONFIG = Autoloads.parse_config(Dict{String, Any}())
const REGISTRY = Autoloads.build_registry(CATALOG,
    Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => v"1.0.0" for id in (DATAFRAMES, BENCHMARKTOOLS, OTHER)), CONFIG)

complete(prefix, qualifier = nothing; bound = Symbol[]) =
    Ext.completions_for(REGISTRY, CATALOG, prefix, qualifier, in(bound))

@testset "completions_for" begin
    @test complete("DataFr") == ["DataFrame", "DataFrames"]
    @test complete("DataFr"; bound = [:DataFrame]) == ["DataFrames"]
    @test complete("@bt") == ["@btime"]
    @test isempty(complete("sha"))  # ambiguous
    @test isempty(complete("meta"))  # public only
    @test complete("gr", :DataFrames) == ["groupby"]
    @test complete("met", :DataFrames) == ["metadata"]
    @test complete("", :BenchmarkTools) == ["@btime", "BenchmarkTools"]
    @test isempty(complete("gr", :DataFrames; bound = [:DataFrames]))
    @test isempty(complete("gr", :Unknown))
    @test isempty(complete("gr", :DataFrame))  # owned name, not a package
end

@testset "completion context" begin
    context(full, prefix) = Ext.completion_context(full, (ncodeunits(full) - ncodeunits(prefix)) => ncodeunits(full))
    @test context("x = f(DataFr", "DataFr") == ("DataFr", nothing)
    @test context("DataFrames.gr", "gr") == ("gr", :DataFrames)
    @test context("1 + DataFrames.", "") == ("", :DataFrames)
    @test context("ünï.α", "α") == ("α", :ünï)
    @test context("@bt", "@bt") == ("@bt", nothing)
    @test context("\"a \$(DataFr", "DataFr") == ("DataFr", nothing)
    for (full, prefix) in [("A.DataFrames.gr", "gr"), ("x + ", ""), ("using DataFr", "DataFr"),
                           ("1\n import Foo, DataFr", "DataFr"), ("\"DataFr", "DataFr"), ("d[\"DataFr", "DataFr"),
                           ("`ls DataFr", "DataFr"), ("x = 1\n\"DataFr", "DataFr")]
        @test context(full, prefix) === nothing
    end
end

# A provider and prompt state standing in for the REPL's.
mutable struct StubProvider <: LineEdit.CompletionProvider
    modifiers::LineEdit.Modifiers
end

struct StubState
    text::String
end

LineEdit.input_string(s::StubState) = s.text
LineEdit.setmodifiers!(c::StubProvider, m::LineEdit.Modifiers) = (c.modifiers = m)
LineEdit.complete_line(::StubProvider, s::StubState, ::Module; hint::Bool = false) =
    NamedCompletion[NamedCompletion("DataFrame"), NamedCompletion("Data")], 0 => ncodeunits(s.text), true

@testset "completion wrapper" begin
    stub = StubProvider(LineEdit.Modifiers())
    wrapper = Ext.CompletionWrapper(stub)
    previous = @atomic Ext.SESSION.session
    try
        @atomic Ext.SESSION.session = Ext.Session(CATALOG, REGISTRY, CONFIG, "", Set{String}())
        completions, region, should_complete = LineEdit.complete_line(wrapper, StubState("DataFr"), Main)
        @test completions isa Vector{NamedCompletion}
        @test [c.completion for c in completions] == ["Data", "DataFrame", "DataFrames"]
        @test (region, should_complete) == (0 => 6, true)
        inner_only = LineEdit.complete_line(wrapper, StubState("DataFr"), Base)
        @test [c.completion for c in inner_only[1]] == ["DataFrame", "Data"]
    finally
        @atomic Ext.SESSION.session = previous
    end
    LineEdit.setmodifiers!(wrapper, LineEdit.Modifiers(true))
    @test stub.modifiers.shift
end

end
