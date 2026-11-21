# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Subprocess half of test_session.jl: runs one case group of the session
# worker and REPL transform against a prepared workspace, exiting non-zero if
# any test fails. Inputs are shaped and evaluated as the REPL does.
#
#     julia [--project=<env>] session_cases.jl <group> <Autoloads test project> <extra>...
#
# The session's member and catalog are the defaults, under the depot path and
# state directory the parent gives.

using Test, Logging

const GROUP, TEST_PROJECT = ARGS[1:2]
const EXTRA = ARGS[3:end]
const DEFAULT_LOAD_PATH = copy(LOAD_PATH)
const START_PROJECT = Base.active_project()
# setup.jl sandboxes the state directory afresh, but this one is the parent's.
const STATE_HOME = ENV["XDG_STATE_HOME"]
# Autoloads comes from its test project, which must not stay on LOAD_PATH.
push!(LOAD_PATH, TEST_PROJECT)
using Autoloads, REPL, Future
include("setup.jl")
copy!(LOAD_PATH, DEFAULT_LOAD_PATH)
ENV["XDG_STATE_HOME"] = STATE_HOME
const MEMBER, CATALOG = Autoloads.memberdir(), Autoloads.catalogpath()

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const iscandidate = Autoloads.iscandidate
const WAIT_S = 120
const THREADS_ID = Base.PkgId(nothing, "Base.Threads")
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const STATISTICS_ID = Base.PkgId(Base.UUID("10745b16-79ce-11e8-11f9-7d13ad32a3b2"), "Statistics")
const DISTRIBUTED_ID = Base.PkgId(Base.UUID("8ba89e20-285c-5b6f-9357-94700520ee1b"), "Distributed")

replinput(s) = REPL.softscope(Base.parse_input_line(s))

"Evaluate transformed input `ex` in `Main` one statement at a time, as `REPL.toplevel_eval_with_hooks` does."
function evalinput(ex)
    Meta.isexpr(ex, :toplevel) || return Core.eval(Main, ex)
    value = nothing
    for arg in ex.args
        arg isa LineNumberNode || (value = evalinput(arg))
    end
    value
end

runinput(s) = evalinput(Ext.repltransform(replinput(s)))

"Evaluate `s` as help-mode input, returning the documentation's text."
runhelp(s) = string(evalinput(Ext.repltransform(REPL.softscope(REPL.helpmode(devnull, s, Main)))))

currentsession() = @atomic Ext.SESSION.session

"Whether `pred(currentsession())` comes to hold."
eventually(pred) = timedwait(() -> pred(currentsession()), WAIT_S; pollint = 0.05) === :ok

"Wait until `pred(currentsession())` holds, and return the session."
function awaitsession(pred = !isnothing)
    eventually(pred) ||
        error("Session never satisfied the condition within $WAIT_S s; indexer log:\n",
              if isfile(CATALOG * ".log") read(CATALOG * ".log", String) else "(none)" end)
    currentsession()
end

"Wait until the worker has handled every event posted so far."
function flushworker(events = Ext.RUNTIME[].events)
    done = Channel{Nothing}(1)
    put!(events, Ext.Flush(done))
    timedwait(() -> isready(done), WAIT_S; pollint = 0.05) === :ok ||
        error("The session worker did not handle a flush within $WAIT_S s")
end

autoloads(name) = s -> s !== nothing && iscandidate(s.registry, name)
notautoloads(name) = s -> s === nothing || !iscandidate(s.registry, name)
isloaded(id) = haskey(Base.loaded_modules, id)
cataloglines() = readlines(CATALOG)

if GROUP == "member"
    @testset "before the first session" begin
        ex = replinput("fa()")
        @test Ext.repltransform(ex) === ex
        events = Channel{Ext.Event}(Inf)
        Ext.ObserveLoad(events)(FIXTURE_A)
        @test take!(events) == Ext.Observed(FIXTURE_A) && !isready(events)
        @test currentsession() === nothing && !isfile(CATALOG * ".log")
    end
    Ext.startsession!()
    @test any(cb -> cb isa Ext.ObserveLoad, Base.package_callbacks)
    @testset "indexes the member and autoloads from it" begin
        awaitsession(autoloads(:fa))
        @test runinput("fa()") === :fa
        @test isdefined(Main, :fa) && LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "member-only using" begin
        runinput("using FixtureA")
        @test LOAD_PATH == DEFAULT_LOAD_PATH
        @test runinput("@time using FixtureA") === nothing
        @test LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "changes" begin
        script = "using Pkg; Pkg.develop(path = ARGS[1])"
        output = IOBuffer()
        develop = runjulia(`-e $script $(joinpath(FIXTURES_DIR, "FixtureB"))`; project = MEMBER, output,
                            env = ("JULIA_PKG_OFFLINE" => "true", "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
        wait(develop)
        success(develop) || error("Developing FixtureB failed:\n", String(take!(output)))
        runinput("1 + 1")
        awaitsession(autoloads(:fb))
        @test runinput("fb()") === :fa
        before = currentsession()
        Autoloads.notifyenvchange()
        @test awaitsession(s -> s !== before) isa Ext.Session
    end
elseif GROUP == "sequencing"
    Ext.startsession!()
    awaitsession(autoloads(:fa))
    @testset "statement sequencing" begin
        @test runinput("FA_CONST = 1; FA_CONST + 1") == 2
        @test !isloaded(FIXTURE_A)
        @test runinput("macro fam() end; @fam") === nothing
        @test !isloaded(FIXTURE_A)
        @test_throws MethodError runinput("x = 1; fa(x)")
        @test isloaded(FIXTURE_A)
    end
    @testset "only environment changes forget failed loads" begin
        failing = Base.PkgId(Base.UUID(0xfa11), "Failing")
        runinput("1")
        push!(Ext.LOAD.failed, failing)
        touch(CATALOG)
        runinput("1")
        @test failing in Ext.LOAD.failed
        touch(joinpath(dirname(MEMBER), "Project.toml"))
        runinput("1")
        @test isempty(Ext.LOAD.failed)
        push!(Ext.LOAD.failed, failing)
        touch(joinpath(MEMBER, "Project.toml"))
        runinput("1")
        @test isempty(Ext.LOAD.failed)
    end
    @testset "a stopped worker handles no more batches" begin
        flushworker()
        before = currentsession()
        Ext.stopworker!(Ext.RUNTIME[])
        Autoloads.notifyenvchange()
        flushworker()
        @test currentsession() === before
    end
elseif GROUP == "macro"
    Ext.startsession!()
    awaitsession(autoloads(Symbol("@fam")))
    @testset "a macro's owner loads in preparestatement" begin
        ex = Ext.repltransform(replinput("@fam 1"))
        prepared = only(filter(arg -> !(arg isa LineNumberNode), ex.args))
        @test Meta.isexpr(prepared, :toplevel) && length(prepared.args) == 2
        Core.eval(Main, prepared.args[1])
        @test isloaded(FIXTURE_A)
        @test evalinput(prepared.args[2]) == 1
    end
elseif GROUP == "stdlib"
    brokenproject = only(EXTRA)
    @testset "batching" begin
        runtime = Ext.Runtime(Channel{Ext.Event}(Inf), MEMBER, CATALOG)
        extension = Base.PkgId(Ext)
        ids = [Base.PkgId(Autoloads), extension]
        foreach(i -> put!(runtime.events, Ext.Observed(ids[mod1(i, length(ids))])), 1:50)
        worker = Ext.Worker(runtime, Ext.Indexer())
        before = cataloglines()
        logs, _ = Test.collect_test_logs(min_level = Logging.Debug) do
            batch = Ext.Event[]
            while isready(runtime.events)
                push!(batch, take!(runtime.events))
            end
            Ext.handlebatch!(worker, batch)
        end
        @test !isready(runtime.events)
        @test count(log -> log.message == "Autoloads session refreshed", logs) == 1
        added = setdiff(cataloglines(), before)
        @test length(added) == 1 && occursin("\tAutoloads\t", only(added))
        @test currentsession() isa Ext.Session
        @atomic Ext.SESSION.session = nothing
    end
    @testset "a ConfigError is logged once" begin
        Base.set_active_project(joinpath(brokenproject, "Project.toml"))
        logger = Test.TestLogger(min_level = Logging.Warn)
        with_logger(Ext.startsession!, logger)
        flushworker()
        foreach(_ -> (Autoloads.notifyenvchange(); flushworker()), 1:3)
        @test length(logger.logs) == 1
        @test only(logger.logs).kwargs[:exception] isa Autoloads.ConfigError
        @testset "input without a session passes unchanged" begin
            ex = replinput("@spawn 1")
            @test Ext.repltransform(ex) === ex
        end
        @testset "a recurring refresh failure is logged once" begin
            halfsaved = joinpath(mktempdir(), "Project.toml")
            write(halfsaved, "[deps\n")
            Base.set_active_project(halfsaved)
            foreach(_ -> (Autoloads.notifyenvchange(); flushworker()), 1:3)
            @test count(log -> log.message == "Autoloads failed to update its session", logger.logs) == 1
        end
    end
    @testset "stdlib" begin
        Base.set_active_project(START_PROJECT)
        runinput("1")
        awaitsession(autoloads(Symbol("@spawn")))
        @test runinput("fetch(@spawn 1)") == 1
        @test isdefined(Main, Symbol("@spawn")) && (THREADS_ID, nothing) in Ext.LOAD.attempted
        @test iscandidate(currentsession().registry, :Pkg) && !isloaded(PKG_ID)
        ex = replinput("status")
        @test Ext.repltransform(ex) == ex
        @test_throws UndefVarError runinput("status")
        @test !isloaded(PKG_ID)
    end
    @testset "a bare name" begin
        @test !isloaded(STATISTICS_ID)
        @test runinput("mean") isa Function
        @test isloaded(STATISTICS_ID)
    end
    @testset "help mode" begin
        @test !isloaded(DISTRIBUTED_ID)
        @test occursin("No documentation found", runhelp("no_such_name"))
        @test !isloaded(DISTRIBUTED_ID)
        @test occursin("pmap(f", runhelp("pmap"))
        @test isloaded(DISTRIBUTED_ID) && isdefined(Main, :pmap)
    end
elseif GROUP == "project"
    unselected, without, selecting = (joinpath(dir, "Project.toml") for dir in EXTRA)
    Ext.startsession!()
    @testset "project autoloads without a member" begin
        awaitsession(autoloads(:fa))
        @test runinput("fa()") === :fa
        @test startswith(pathof(Main.FixtureA), FIXTURES_DIR) && LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "observation" begin
        flushworker()
        before = cataloglines()
        runinput("using FixtureB")
        flushworker()
        added = setdiff(cataloglines(), before)
        @test length(added) == 1 && occursin("\tFixtureB\t", only(added))
    end
    activate!(project) = (Base.set_active_project(project); runinput("1"))
    @testset "only the active project's selected deps" begin
        activate!(unselected)
        @test eventually(notautoloads(:fa))
        activate!(selecting)
        @test eventually(autoloads(:fa))
        activate!(without)
        @test eventually(notautoloads(:fa))
        activate!(selecting)
        @test eventually(autoloads(:fa))
        push!(LOAD_PATH, dirname(selecting))
        activate!(without)
        @test eventually(notautoloads(:fa))
        pop!(LOAD_PATH)
    end
    @testset "local preferences beside the active project" begin
        activate!(selecting)
        @test eventually(autoloads(:fa))
        localprefs = joinpath(dirname(selecting), "LocalPreferences.toml")
        write(localprefs, "[Autoloads]\nproject = []\n")
        runinput("1")
        @test eventually(notautoloads(:fa))
        rm(localprefs)
        runinput("1")
        @test eventually(autoloads(:fa))
    end
elseif GROUP == "hints"
    bare = joinpath(only(EXTRA), "Project.toml")
    onlyb = Base.active_project()
    Ext.startsession!()
    awaitsession()
    hintfor(name, scope = Main) = sprint(Ext.undefvarhint, UndefVarError(name, scope))
    activate!(project) = (Base.set_active_project(project); runinput("1"); flushworker())
    header(name) = "\nHint: $name is provided by packages that are not loaded:\n"
    @testset "ranking by availability in the active project" begin
        @test hintfor(:fa) == header(:fa) *
            "  • using FixtureB  (a dependency of the active project, re-exports it from FixtureA)\n" *
            "  • pkg> add FixtureA  (already resolved in the active project's manifest)\n" *
            "  • pkg> add FixtureC  (already resolved in the active project's manifest)"
    end
    @testset "names not provided by the catalog, or outside Main" begin
        @test hintfor(:no_such_name) == ""
        @test hintfor(:fa, Base) == ""
    end
    @testset "stdlib provider" begin
        @test occursin("using Statistics  (from @stdlib)", hintfor(:mean))
    end
    activate!(bare)
    @testset "providers outside the active project and load path" begin
        @test hintfor(:fa) == header(:fa) *
            "  • using FixtureA  (an autoload package)\n" *
            "  • pkg> add FixtureC  (or pkg> autoloads add FixtureC)\n" *
            "  • pkg> add FixtureB  (or pkg> autoloads add FixtureB, re-exports it from FixtureA and FixtureC)"
    end
    @testset "load path environments" begin
        envdir = joinpath(DEPOT_PATH[1], "environments", "extras")
        mkpath(envdir)
        write(joinpath(envdir, "Project.toml"), "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
        push!(LOAD_PATH, "@extras")
        @test startswith(hintfor(:fa), header(:fa) * "  • using FixtureC  (from @extras)\n")
        pop!(LOAD_PATH)
        pathdir = mktempdir()
        write(joinpath(pathdir, "Project.toml"), "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
        push!(LOAD_PATH, pathdir)
        @test occursin("using FixtureC  (from $(joinpath(pathdir, "Project.toml")))", hintfor(:fa))
        pop!(LOAD_PATH)
    end
    activate!(onlyb)
    @testset "a name a loaded module provides" begin
        runinput("using FixtureB")
        @test isloaded(FIXTURE_B) && hintfor(:fa) == ""
    end
elseif GROUP == "hints-bare"
    hintfor(name) = sprint(Ext.undefvarhint, UndefVarError(name, Main))
    initnote = "  • pkg> add Stranger  (run pkg> autoloads init to autoload packages)"
    @testset "without a session the catalog file is read on demand" begin
        @test currentsession() === nothing
        @test occursin("using FixtureB  (a dependency of the active project)", hintfor(:fb))
        @test endswith(hintfor(:stranger_fn), initnote)
        # A member is found on disk.
        write(joinpath(mkpath(MEMBER), "Project.toml"), "")
        @test endswith(hintfor(:stranger_fn), "  • pkg> add Stranger  (or pkg> autoloads add Stranger)")
        rm(MEMBER; recursive = true)
    end
    @testset "a session without a member gives the same note" begin
        Ext.startsession!()
        awaitsession()
        @test currentsession() !== nothing
        @test endswith(hintfor(:stranger_fn), initnote)
    end
elseif GROUP == "observe-again"
    Ext.startsession!()
    awaitsession(autoloads(:fa))
    @testset "a known namespace is not rewritten" begin
        flushworker()
        before = (read(CATALOG), mtime(CATALOG))
        runinput("using FixtureB")
        @test isloaded(FIXTURE_B)
        flushworker()
        @test (read(CATALOG), mtime(CATALOG)) == before
    end
elseif GROUP == "unwritable"
    @testset "an unwritable catalog still gives a session" begin
        logger = Test.TestLogger(min_level = Logging.Warn)
        with_logger(Ext.startsession!, logger)
        @test Ext.startsession!() === Ext.RUNTIME[]
        awaitsession(autoloads(:fa))
        events = Ext.RUNTIME[].events
        for _ in 1:3
            before = currentsession()
            put!(events, Ext.Observed(Base.PkgId(Test)))
            put!(events, Ext.Refresh())
            flushworker()
            @test currentsession() !== before
        end
        @test length(logger.logs) == 1
        @test only(logger.logs).message == "Autoloads failed to record loaded packages in its catalog"
    end
else
    error("Unknown session case group $(repr(GROUP))")
end
