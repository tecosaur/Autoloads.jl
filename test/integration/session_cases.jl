# Subprocess half of test_session.jl: runs one case group of the session
# worker and REPL transform against a prepared workspace, exiting non-zero if
# any test fails. Inputs are shaped and evaluated as the REPL does.
#
#     julia [--project=<env>] session_cases.jl <group> <Autoloads test project> <member> <catalog> <extra>...

using Test, Logging

const GROUP, TEST_PROJECT, MEMBER, CATALOG = ARGS[1:4]
const EXTRA = ARGS[5:end]
const DEFAULT_LOAD_PATH = copy(LOAD_PATH)
const START_PROJECT = Base.active_project()
# Autoloads comes from its test project, which must not stay on LOAD_PATH.
push!(LOAD_PATH, TEST_PROJECT)
using Autoloads, REPL
include("setup.jl")
copy!(LOAD_PATH, DEFAULT_LOAD_PATH)

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const is_candidate = Autoloads.is_candidate
const WAIT_S = 120
const THREADS_ID = Base.PkgId(nothing, "Base.Threads")
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")

repl_input(s) = REPL.softscope(Base.parse_input_line(s))

"Evaluate transformed input `ex` in `Main` one statement at a time, as `REPL.toplevel_eval_with_hooks` does."
function eval_input(ex)
    Meta.isexpr(ex, :toplevel) || return Core.eval(Main, ex)
    value = nothing
    for arg in ex.args
        arg isa LineNumberNode || (value = eval_input(arg))
    end
    value
end

run_input(s) = eval_input(Ext.repl_transform(repl_input(s)))

current_session() = @atomic Ext.SESSION.session

"Whether `pred(current_session())` comes to hold."
eventually(pred) = timedwait(() -> pred(current_session()), WAIT_S; pollint = 0.05) === :ok

"Wait until `pred(current_session())` holds, and return the session."
function await_session(pred = !isnothing)
    eventually(pred) ||
        error("Session never satisfied the condition within $WAIT_S s; indexer log:\n",
              isfile(CATALOG * ".log") ? read(CATALOG * ".log", String) : "(none)")
    current_session()
end

"Wait until the worker has handled every event posted so far."
function flush_worker(events = Ext.RUNTIME[].events)
    done = Channel{Nothing}(1)
    put!(events, Ext.Flush(done))
    timedwait(() -> isready(done), WAIT_S; pollint = 0.05) === :ok ||
        error("The session worker did not handle a flush within $WAIT_S s")
end

autoloads(name) = s -> s !== nothing && is_candidate(s.registry, name)
not_autoloads(name) = s -> s === nothing || !is_candidate(s.registry, name)
is_loaded(id) = haskey(Base.loaded_modules, id)
catalog_lines() = readlines(CATALOG)
start_session!() = Ext.start_session!(; member = MEMBER, catalog = CATALOG)

if GROUP == "member"
    @testset "before the first session" begin
        ex = repl_input("fa()")
        @test Ext.repl_transform(ex) === ex
        events = Channel{Ext.Event}(Inf)
        Ext.ObserveLoad(events)(FIXTURE_A)
        @test take!(events) == Ext.Observed(FIXTURE_A) && !isready(events)
        @test current_session() === nothing && !isfile(CATALOG * ".log")
    end
    start_session!()
    @test any(cb -> cb isa Ext.ObserveLoad, Base.package_callbacks)
    @testset "indexes the member and autoloads from it" begin
        await_session(autoloads(:fa))
        @test run_input("fa()") === :fa
        @test isdefined(Main, :fa) && LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "member-only using" begin
        run_input("using FixtureA")
        @test LOAD_PATH == DEFAULT_LOAD_PATH
        @test run_input("@time using FixtureA") === nothing
        @test LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "changes" begin
        script = "using Pkg; Pkg.develop(path = ARGS[1])"
        output = IOBuffer()
        develop = Autoloads.run_julia(`-e $script $(joinpath(FIXTURES_DIR, "FixtureB"))`; project = MEMBER, output,
                                      env = ("JULIA_PKG_OFFLINE" => "true", "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
        wait(develop)
        success(develop) || error("Developing FixtureB failed:\n", String(take!(output)))
        run_input("1 + 1")
        await_session(autoloads(:fb))
        @test run_input("fb()") === :fa
        before = current_session()
        Autoloads.notify_env_change()
        @test await_session(s -> s !== before) isa Ext.Session
    end
elseif GROUP == "sequencing"
    start_session!()
    await_session(autoloads(:fa))
    @testset "statement sequencing" begin
        @test run_input("FA_CONST = 1; FA_CONST + 1") == 2
        @test !is_loaded(FIXTURE_A)
        @test run_input("macro fam() end; @fam") === nothing
        @test !is_loaded(FIXTURE_A)
        @test_throws MethodError run_input("x = 1; fa(x)")
        @test is_loaded(FIXTURE_A)
    end
elseif GROUP == "macro"
    start_session!()
    await_session(autoloads(Symbol("@fam")))
    @testset "a macro's owner loads in prepare_statement" begin
        ex = Ext.repl_transform(repl_input("@fam 1"))
        prepared = only(filter(arg -> !(arg isa LineNumberNode), ex.args))
        @test Meta.isexpr(prepared, :toplevel) && length(prepared.args) == 2
        Core.eval(Main, prepared.args[1])
        @test is_loaded(FIXTURE_A)
        @test eval_input(prepared.args[2]) == 1
    end
elseif GROUP == "stdlib"
    broken_project = only(EXTRA)
    @testset "batching" begin
        runtime = Ext.Runtime(Channel{Ext.Event}(Inf), MEMBER, CATALOG)
        extension = Base.PkgId(Ext)
        ids = [Base.PkgId(Autoloads), extension]
        foreach(i -> put!(runtime.events, Ext.Observed(ids[mod1(i, length(ids))])), 1:50)
        worker = Ext.Worker(runtime, Ext.Indexer())
        before = catalog_lines()
        logs, _ = Test.collect_test_logs(min_level = Logging.Debug) do
            Ext.handle_batch!(worker, Ext.next_batch!(runtime.events))
        end
        @test !isready(runtime.events)
        @test count(log -> log.message == "Autoloads session refreshed", logs) == 1
        added = setdiff(catalog_lines(), before)
        @test length(added) == 1 && occursin("\tAutoloads\t", only(added))
        @test current_session() isa Ext.Session
        @atomic Ext.SESSION.session = nothing
    end
    @testset "a ConfigError is logged once" begin
        Base.set_active_project(joinpath(broken_project, "Project.toml"))
        logger = Test.TestLogger(min_level = Logging.Warn)
        with_logger(start_session!, logger)
        flush_worker()
        foreach(_ -> (Autoloads.notify_env_change(); flush_worker()), 1:3)
        @test length(logger.logs) == 1
        @test only(logger.logs).kwargs[:exception] isa Autoloads.ConfigError
        @testset "input without a session passes unchanged" begin
            ex = repl_input("@spawn 1")
            @test Ext.repl_transform(ex) === ex
        end
    end
    @testset "stdlib" begin
        Base.set_active_project(START_PROJECT)
        run_input("1")
        await_session(autoloads(Symbol("@spawn")))
        @test run_input("fetch(@spawn 1)") == 1
        @test isdefined(Main, Symbol("@spawn")) && (THREADS_ID, nothing) in Ext.LOAD.attempted
        @test is_candidate(current_session().registry, :Pkg) && !is_loaded(PKG_ID)
        ex = repl_input("status")
        @test Ext.repl_transform(ex) == ex
        @test_throws UndefVarError run_input("status")
        @test !is_loaded(PKG_ID)
    end
elseif GROUP == "project"
    unselected, without, selecting = (joinpath(dir, "Project.toml") for dir in EXTRA)
    start_session!()
    @testset "project autoloads without a member" begin
        await_session(autoloads(:fa))
        @test run_input("fa()") === :fa
        @test startswith(pathof(Main.FixtureA), FIXTURES_DIR) && LOAD_PATH == DEFAULT_LOAD_PATH
    end
    @testset "observation" begin
        flush_worker()
        before = catalog_lines()
        run_input("using FixtureB")
        flush_worker()
        added = setdiff(catalog_lines(), before)
        @test length(added) == 1 && occursin("\tFixtureB\t", only(added))
    end
    activate!(project) = (Base.set_active_project(project); run_input("1"))
    @testset "only the active project's selected deps" begin
        activate!(unselected)
        @test eventually(not_autoloads(:fa))
        activate!(selecting)
        @test eventually(autoloads(:fa))
        activate!(without)
        @test eventually(not_autoloads(:fa))
        activate!(selecting)
        @test eventually(autoloads(:fa))
        push!(LOAD_PATH, dirname(selecting))
        activate!(without)
        @test eventually(not_autoloads(:fa))
        pop!(LOAD_PATH)
    end
    @testset "local preferences beside the active project" begin
        activate!(selecting)
        @test eventually(autoloads(:fa))
        local_prefs = joinpath(dirname(selecting), "LocalPreferences.toml")
        write(local_prefs, "[Autoloads]\nproject = []\n")
        run_input("1")
        @test eventually(not_autoloads(:fa))
        rm(local_prefs)
        run_input("1")
        @test eventually(autoloads(:fa))
    end
elseif GROUP == "hints"
    bare = joinpath(only(EXTRA), "Project.toml")
    only_b = Base.active_project()
    start_session!()
    await_session()
    hint_for(name, scope = Main) = sprint(Ext.undefvar_hint, UndefVarError(name, scope))
    activate!(project) = (Base.set_active_project(project); run_input("1"); flush_worker())
    header(name) = "\nHint: $name is provided by packages that are not loaded:\n"
    @testset "ranking by availability in the active project" begin
        @test hint_for(:fa) == header(:fa) *
            "    - `using FixtureB` (a dependency of the active project), which re-exports it from FixtureA\n" *
            "    - `pkg> add FixtureA` (already resolved in the active project's manifest)\n" *
            "    - `pkg> add FixtureC` (already resolved in the active project's manifest)"
    end
    @testset "names not provided by the catalog, or outside Main" begin
        @test hint_for(:no_such_name) == ""
        @test hint_for(:fa, Base) == ""
    end
    @testset "stdlib provider" begin
        @test occursin("`using Statistics` (from @stdlib)", hint_for(:mean))
    end
    activate!(bare)
    @testset "providers that are only available elsewhere" begin
        @test hint_for(:fa) == header(:fa) *
            "    - `pkg> add FixtureA`, or `pkg> autoloads add FixtureA`\n" *
            "    - `pkg> add FixtureC`, or `pkg> autoloads add FixtureC`\n" *
            "    - `pkg> add FixtureB`, or `pkg> autoloads add FixtureB`, which re-exports it from FixtureA and FixtureC"
    end
    @testset "load path environments" begin
        env_dir = joinpath(DEPOT_PATH[1], "environments", "extras")
        mkpath(env_dir)
        write(joinpath(env_dir, "Project.toml"), "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
        push!(LOAD_PATH, "@extras")
        @test startswith(hint_for(:fa), header(:fa) * "    - `using FixtureC` (from @extras)\n")
        pop!(LOAD_PATH)
        path_dir = mktempdir()
        write(joinpath(path_dir, "Project.toml"), "[deps]\nFixtureC = \"$(FIXTURE_C.uuid)\"\n")
        push!(LOAD_PATH, path_dir)
        @test occursin("`using FixtureC` (from $(joinpath(path_dir, "Project.toml")))", hint_for(:fa))
        pop!(LOAD_PATH)
    end
    activate!(only_b)
    @testset "a name a loaded module provides" begin
        run_input("using FixtureB")
        @test is_loaded(FIXTURE_B) && hint_for(:fa) == ""
    end
elseif GROUP == "hints-bare"
    hint_for(name) = sprint(Ext.undefvar_hint, UndefVarError(name, Main))
    init_note = "    - `pkg> add Stranger` (run `pkg> autoloads init` to autoload packages)"
    @testset "without a session the catalog file is read on demand" begin
        mkpath(dirname(Autoloads.catalog_path()))
        cp(CATALOG, Autoloads.catalog_path())
        @test current_session() === nothing
        @test occursin("`using FixtureB` (a dependency of the active project)", hint_for(:fb))
        # The depot's global environment has a member, which the hint finds on disk.
        @test endswith(hint_for(:stranger_fn), "    - `pkg> add Stranger`, or `pkg> autoloads add Stranger`")
    end
    @testset "a session without a member gives the same note" begin
        start_session!()
        await_session()
        @test current_session() !== nothing
        @test endswith(hint_for(:stranger_fn), init_note)
    end
elseif GROUP == "observe-again"
    start_session!()
    await_session(autoloads(:fa))
    @testset "a known namespace is not rewritten" begin
        flush_worker()
        before = (read(CATALOG), mtime(CATALOG))
        run_input("using FixtureB")
        @test is_loaded(FIXTURE_B)
        flush_worker()
        @test (read(CATALOG), mtime(CATALOG)) == before
    end
elseif GROUP == "unwritable"
    @testset "an unwritable catalog still gives a session" begin
        logger = Test.TestLogger(min_level = Logging.Warn)
        with_logger(start_session!, logger)
        @test start_session!() === Ext.RUNTIME[]
        await_session(autoloads(:fa))
        events = Ext.RUNTIME[].events
        for _ in 1:3
            before = current_session()
            put!(events, Ext.Observed(Base.PkgId(Test)))
            put!(events, Ext.Refresh())
            flush_worker()
            @test current_session() !== before
        end
        @test length(logger.logs) == 1
        @test only(logger.logs).message == "Autoloads failed to record loaded packages in its catalog"
    end
else
    error("Unknown session case group $(repr(GROUP))")
end
