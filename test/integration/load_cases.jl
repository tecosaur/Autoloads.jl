# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Subprocess half of test_load.jl: runs one case group of `load!` and
# `evalwithmember` against the shared workspace, exiting non-zero if any
# test fails.
#
#     julia [--project=<env>] load_cases.jl <group> <Autoloads test project> <member>

using Test, Logging

const GROUP, TEST_PROJECT, MEMBER = ARGS
const DEFAULT_LOAD_PATH = copy(LOAD_PATH)
# Autoloads comes from its test project, which must not stay on LOAD_PATH.
push!(LOAD_PATH, TEST_PROJECT)
using Autoloads, REPL, Future
include("setup.jl")
copy!(LOAD_PATH, DEFAULT_LOAD_PATH)
const LoadRequest = Autoloads.LoadRequest

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const FIXTURE_MISSING = Base.PkgId(Base.UUID("d0d0d0d0-4444-4444-8444-00000000000d"), "FixtureMissing")

"Run `load!`, returning its result and the `(level, message, exception text)` of each log."
function loggedload!(state, req; kwargs...)
    logs, loaded = Test.collect_test_logs(() -> Ext.load!(state, req, MEMBER; kwargs...))
    @test LOAD_PATH == DEFAULT_LOAD_PATH
    exceptiontext(log) = if haskey(log.kwargs, :exception) sprint(showerror, first(log.kwargs[:exception])) else "" end
    loaded, [(log.level, log.message, exceptiontext(log)) for log in logs]
end

"Whether the only logs are one info line and then one warning whose exception text satisfies `pred`."
function warnedonce(logs, pred)
    length(logs) == 2 || return false
    (level, _, text) = last(logs)
    first(first(logs)) == Logging.Info && level == Logging.Warn && pred(text)
end

if GROUP == "global"
    @testset "global environment" begin
        state = Ext.LoadState()
        @test loggedload!(state, LoadRequest(FIXTURE_A, :fa, nothing)) ==
            (true, [(Logging.Info, "Autoloading FixtureA (for fa)", "")])
        @test isdefined(Main, :fa) && isdefined(Main, :FA_CONST)
        @test (FIXTURE_A, nothing) in state.attempted
        @test loggedload!(state, LoadRequest(Base.PkgId(nothing, "Base.Threads"), :nthreads, nothing);
                           announce = false) == (true, [])
        @test isdefined(Main, :nthreads)
        @testset "extension resolution" begin
            # The trigger resolves through `@v#.#` alone, with the member absent.
            @test LOAD_PATH == DEFAULT_LOAD_PATH
            Base.require(FIXTURE_C)
            @test Base.get_extension(Main.FixtureA, :FixtureAFixtureCExt) isa Module
        end
        @testset "failure is remembered" begin
            ENV["FIXTUREB_FAIL"] = "1"
            b = LoadRequest(FIXTURE_B, :fb, nothing)
            loaded, logs = loggedload!(state, b)
            @test !loaded && warnedonce(logs, text -> occursin("FIXTUREB_FAIL", text))
            @test FIXTURE_B in state.failed
            @test loggedload!(state, b) == (false, [])
            @test (FIXTURE_B, nothing) in state.attempted
        end
        @testset "forgotten failures are retried" begin
            delete!(ENV, "FIXTUREB_FAIL")
            Ext.forgetfailures!(state)
            @test isempty(state.failed) && (FIXTURE_B, nothing) ∉ state.attempted
            @test first(loggedload!(state, LoadRequest(FIXTURE_B, :fb, nothing)))
        end
        @testset "not installed" begin
            loaded, logs = loggedload!(state, LoadRequest(FIXTURE_MISSING, :fm, nothing))
            @test !loaded && warnedonce(logs, text -> endswith(text,
                "run `pkg> instantiate` with the global environment active to install it"))
        end
        @testset "a pre-existing member entry survives" begin
            push!(LOAD_PATH, MEMBER)
            missingagain = LoadRequest(Base.PkgId(Base.UUID(0xe0), "FixtureMissingToo"), :fm2, nothing)
            _, loaded = Test.collect_test_logs(() -> Ext.load!(state, missingagain, MEMBER))
            @test !loaded && LOAD_PATH == [DEFAULT_LOAD_PATH; MEMBER]
            pop!(LOAD_PATH)
        end
    end
elseif GROUP == "used"
    @testset "used bindings" begin
        state = Ext.LoadState()
        @test first(loggedload!(state, LoadRequest(FIXTURE_A, :fa, :fa)))
        @test isdefined(Main, :fa) && !isdefined(Main, :FA_CONST) && !isdefined(Main, :FixtureA)
        @test (FIXTURE_A, :fa) in state.attempted
        @test first(loggedload!(state, LoadRequest(FIXTURE_A, :FixtureA, :FixtureA)))
        @test isdefined(Main, :FixtureA) && !isdefined(Main, :FA_CONST)
        @testset "eval_with_member" begin
            Ext.evalwithmember(:(@time using FixtureA), MEMBER)
            @test isdefined(Main, :FA_CONST)
            @test LOAD_PATH == DEFAULT_LOAD_PATH
        end
        @testset "an interrupted load is not recorded" begin
            c = LoadRequest(FIXTURE_C, :fc, nothing)
            ENV["FIXTUREC_INTERRUPT"] = "1"
            @test_throws InterruptException Test.collect_test_logs(() -> Ext.load!(state, c, MEMBER))
            @test LOAD_PATH == DEFAULT_LOAD_PATH
            @test FIXTURE_C ∉ state.failed && (FIXTURE_C, nothing) ∉ state.attempted
            delete!(ENV, "FIXTUREC_INTERRUPT")
            @test first(loggedload!(state, c))
        end
    end
elseif GROUP == "project"
    @testset "active project provides FixtureA v0.2.0" begin
        @testset "a dependency not yet loaded is checked too" begin
            loaded, logs = loggedload!(Ext.LoadState(), LoadRequest(FIXTURE_B, :fb, nothing))
            @test !loaded && warnedonce(logs, ==("Cannot load FixtureB from the autoloads environment: FixtureA v0.2.0 \
                (from $(Base.contractuser(Base.active_project()))) differs from v0.1.0 there. \
                Add FixtureB to the active project to load it there."))
            @test !haskey(Base.loaded_modules, FIXTURE_A)
        end
        state = Ext.LoadState()
        @test first(loggedload!(state, LoadRequest(FIXTURE_A, :fa, nothing)))
        @test startswith(pathof(Main.FixtureA), dirname(Base.active_project()))
        @test pkgversion(Main.FixtureA) == v"0.2.0"
        loaded, logs = loggedload!(state, LoadRequest(FIXTURE_B, :fb, nothing))
        conflict = "Cannot load FixtureB from the autoloads environment: FixtureA v0.2.0 (already loaded) differs from \
            v0.1.0 there. Add FixtureB to the active project to load it there."
        @test !loaded && warnedonce(logs, ==(conflict))
        @testset "an explicit member using is guarded too" begin
            err = try Ext.evalwithmember(:(using FixtureB), MEMBER) catch e; e end
            @test err isa ErrorException && err.msg == conflict
            @test LOAD_PATH == DEFAULT_LOAD_PATH
        end
        @test !isdefined(Main, :fb)
        @test first(loggedload!(state, LoadRequest(FIXTURE_C, :fc, nothing)))
        @test isdefined(Main, :fc)
    end
else
    error("Unknown load case group $(repr(GROUP)); expected global, used or project")
end
