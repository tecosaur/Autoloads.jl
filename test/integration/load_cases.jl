# Subprocess half of test_load.jl: runs one case group of `load!` and
# `eval_with_member` against the shared workspace, exiting non-zero if any
# test fails.
#
#     julia [--project=<env>] load_cases.jl <group> <Autoloads test project> <member>

using Test, Logging

const GROUP, TEST_PROJECT, MEMBER = ARGS
const DEFAULT_LOAD_PATH = copy(LOAD_PATH)
# Autoloads comes from its test project, which must not stay on LOAD_PATH.
push!(LOAD_PATH, TEST_PROJECT)
using Autoloads, REPL
include("setup.jl")
copy!(LOAD_PATH, DEFAULT_LOAD_PATH)
const LoadRequest = Autoloads.LoadRequest

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const FIXTURE_MISSING = Base.PkgId(Base.UUID("d0d0d0d0-4444-4444-8444-00000000000d"), "FixtureMissing")

"Run `load!`, returning its result and the `(level, message, exception text)` of each log."
function logged_load!(state, req)
    logs, loaded = Test.collect_test_logs(() -> Ext.load!(state, req, MEMBER))
    @test LOAD_PATH == DEFAULT_LOAD_PATH
    exception_text(log) = haskey(log.kwargs, :exception) ? sprint(showerror, first(log.kwargs[:exception])) : ""
    loaded, [(log.level, log.message, exception_text(log)) for log in logs]
end

"Whether the only logs are one info line and then one warning whose exception text satisfies `pred`."
function warned_once(logs, pred)
    length(logs) == 2 || return false
    (level, _, text) = last(logs)
    first(first(logs)) == Logging.Info && level == Logging.Warn && pred(text)
end

if GROUP == "global"
    @testset "global environment" begin
        state = Ext.LoadState()
        @test logged_load!(state, LoadRequest(FIXTURE_A, :fa, nothing)) ==
            (true, [(Logging.Info, "Autoloading FixtureA (for fa)", "")])
        @test isdefined(Main, :fa) && isdefined(Main, :FA_CONST)
        @test (FIXTURE_A, nothing) in state.attempted
        @test first(logged_load!(state, LoadRequest(Base.PkgId(nothing, "Base.Threads"), :nthreads, nothing)))
        @test isdefined(Main, :nthreads)
        @testset "extension resolution" begin
            Ext.eval_with_member(:(using FixtureC), MEMBER)
            @test LOAD_PATH == DEFAULT_LOAD_PATH
            @test Base.get_extension(Main.FixtureA, :FixtureAFixtureCExt) isa Module
        end
        @testset "failure is remembered" begin
            ENV["FIXTUREB_FAIL"] = "1"
            b = LoadRequest(FIXTURE_B, :fb, nothing)
            loaded, logs = logged_load!(state, b)
            @test !loaded && warned_once(logs, text -> occursin("FIXTUREB_FAIL", text))
            @test FIXTURE_B in state.failed
            @test logged_load!(state, b) == (false, [])
            @test (FIXTURE_B, nothing) in state.attempted
        end
        @testset "not installed" begin
            loaded, logs = logged_load!(state, LoadRequest(FIXTURE_MISSING, :fm, nothing))
            @test !loaded && warned_once(logs, text -> endswith(text,
                "Run `pkg> instantiate` with the global environment active to install it."))
        end
    end
elseif GROUP == "used"
    @testset "used bindings" begin
        state = Ext.LoadState()
        @test first(logged_load!(state, LoadRequest(FIXTURE_A, :fa, :fa)))
        @test isdefined(Main, :fa) && !isdefined(Main, :FA_CONST) && !isdefined(Main, :FixtureA)
        @test (FIXTURE_A, :fa) in state.attempted
        @test first(logged_load!(state, LoadRequest(FIXTURE_A, :FixtureA, :FixtureA)))
        @test isdefined(Main, :FixtureA) && !isdefined(Main, :FA_CONST)
        @testset "eval_with_member" begin
            Ext.eval_with_member(:(@time using FixtureA), MEMBER)
            @test isdefined(Main, :FA_CONST)
            @test LOAD_PATH == DEFAULT_LOAD_PATH
        end
    end
elseif GROUP == "project"
    @testset "active project provides FixtureA v0.2.0" begin
        state = Ext.LoadState()
        @test first(logged_load!(state, LoadRequest(FIXTURE_A, :fa, nothing)))
        @test startswith(pathof(Main.FixtureA), dirname(Base.active_project()))
        @test pkgversion(Main.FixtureA) == v"0.2.0"
        loaded, logs = logged_load!(state, LoadRequest(FIXTURE_B, :fb, nothing))
        @test !loaded && warned_once(logs, ==("Not autoloading FixtureB: already-loaded FixtureA v0.2.0 \
            differs from v0.1.0 in the autoloads environment. Add FixtureB to the active project to load it there."))
        @test !isdefined(Main, :fb)
        @test first(logged_load!(state, LoadRequest(FIXTURE_C, :fc, nothing)))
        @test isdefined(Main, :fc)
    end
else
    error("Unknown load case group $(repr(GROUP)); expected global, used or project")
end
