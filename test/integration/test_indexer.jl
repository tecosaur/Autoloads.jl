# A module keeps these helpers apart from the other test files' globals.
module TestIndexer

using Test, REPL, Autoloads
using Autoloads: PkgNames, PkgFailure, read_catalog, manifest_graph, Lazy, Background

include("setup.jl")

const IndexerExt = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const PIDFILE = Base.require(Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")).Pidfile
const INDEXER_WAIT_S = 120

@testset "exit_failure" begin
    exit_failure = IndexerExt.exit_failure
    in_progress = FIXTURE_C => v"0.1.0"
    @test exit_failure(in_progress, 3, 0, false, 300) ==
        PkgFailure(FIXTURE_C, v"0.1.0", "indexer exited with code 3 while indexing")
    @test exit_failure(in_progress, 0, 9, true, 300) ==
        PkgFailure(FIXTURE_C, v"0.1.0", "indexer timed out after 300 s while indexing")
    @test exit_failure(FIXTURE_C => nothing, 1, 0, false, 300) ==
        PkgFailure(FIXTURE_C, nothing, "indexer exited with code 1 while indexing")
    @test exit_failure(in_progress, 0, 11, false, 300) ==
        PkgFailure(FIXTURE_C, v"0.1.0", "indexer killed by signal 11 while indexing")  # segfault
    @test exit_failure(in_progress, 0, 9, false, 300) ==
        PkgFailure(FIXTURE_C, v"0.1.0", "indexer killed by signal 9 while indexing")   # OOM killer
    @test exit_failure(in_progress, 0, 0, false, 300) === nothing   # finished normally
    @test exit_failure(in_progress, 0, 0, true, 300) === nothing    # timer fired as it finished
    @test exit_failure(in_progress, 0, 15, true, 300) === nothing   # stopped by someone else
    for signal in (2, 15, 1)                                        # SIGINT, SIGTERM, SIGHUP
        @test exit_failure(in_progress, 0, signal, false, 300) === nothing
    end
    @test exit_failure(in_progress, 130, 0, false, 300) === nothing # interrupted
    @test exit_failure(nothing, 3, 0, false, 300) === nothing       # before any package
    @test exit_failure(nothing, 0, 9, true, 300) === nothing
end

const WS = build_workspace()
const GRAPH = manifest_graph(joinpath(WS.member, "Project.toml"))
const CACHE_DIR = joinpath(WS.depot, "compiled", "v$(VERSION.major).$(VERSION.minor)")

wanted(ids) = Pair{Base.PkgId, Union{VersionNumber, Nothing}}[id => GRAPH.versions[id.uuid] for id in ids]
records_of(path, id) = filter(r -> r.id == id, read_catalog(path))
names_of(path, id) = only(filter(r -> r isa PkgNames, records_of(path, id)))
failure_of(path, id) = only(filter(r -> r isa PkgFailure, records_of(path, id)))
log_of(path) = isfile(path * ".log") ? read(path * ".log", String) : ""

"Start indexing `ids` into a fresh catalog; returns the catalog path and a channel receiving `changed`."
function start_run(ix, policy, ids; env = (), path = joinpath(mktempdir(), "catalog-v1"))
    done = Channel{Bool}(1)
    started = withenv("JULIA_DEPOT_PATH" => WS.depot_path, "JULIA_LOAD_PATH" => nothing, env...) do
        IndexerExt.start_indexing!(ix, policy, WS.member, path, wanted(ids), changed -> put!(done, changed))
    end
    @test started
    (; path, done)
end

function finish_run((; path, done))
    timedwait(() -> isready(done), INDEXER_WAIT_S) === :ok ||
        error("indexer for $path did not finish within $INDEXER_WAIT_S s; log:\n", log_of(path))
    (; path, changed = take!(done))
end

run_indexer(ix, policy, ids; env = ()) = finish_run(start_run(ix, policy, ids; env))

function test_fixture_a_names(path)
    a = names_of(path, FIXTURE_A)
    @test a.versions == [v"0.1.0"]
    @test a.exported == Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST])
    @test :fa_public in a.public
end

@testset "indexer" begin
    ix = IndexerExt.Indexer()
    @testset "lazy policy writes no caches" begin
        (; path, changed) = run_indexer(ix, Lazy, [FIXTURE_A, FIXTURE_B])
        @test changed
        test_fixture_a_names(path)
        b = names_of(path, FIXTURE_B)
        @test :fa in b.reexported && :fb in b.exported
        @test !isdir(joinpath(CACHE_DIR, "FixtureA"))
        @test occursin("indexing $(FIXTURE_A.uuid)", log_of(path))
    end
    @testset "background policy precompiles; load failures are contained" begin
        (; path, changed) = run_indexer(ix, Background, [FIXTURE_A, FIXTURE_B, FIXTURE_C];
                                        env = ("FIXTUREB_FAIL" => "1",))
        @test changed
        test_fixture_a_names(path)
        failure = failure_of(path, FIXTURE_B)
        @test failure.version == v"0.1.0" && occursin("FIXTUREB_FAIL", failure.message)
        @test :fc in names_of(path, FIXTURE_C).exported
        @test isdir(joinpath(CACHE_DIR, "FixtureA"))
        output = IOBuffer()
        check = "print(Base.isprecompiled(Base.PkgId(Base.UUID(\"$(FIXTURE_A.uuid)\"), \"FixtureA\")))"
        wait(run_julia(`-e $check`; project = WS.member, output,
                       env = ("JULIA_DEPOT_PATH" => WS.depot_path,)))
        @test String(take!(output)) == "true"
    end
    @testset "crash containment" begin
        (; path, changed) = run_indexer(ix, Lazy, [FIXTURE_A, FIXTURE_C, FIXTURE_B];
                                        env = ("FIXTUREC_CRASH" => "1",))
        @test changed
        test_fixture_a_names(path)
        @test failure_of(path, FIXTURE_C) ==
            PkgFailure(FIXTURE_C, v"0.1.0", "indexer exited with code 3 while indexing")
        @test isempty(records_of(path, FIXTURE_B))
        @test !ispath(path * ".indexing")
    end
    @testset "one run at a time; an interrupted run records nothing" begin
        pending = start_run(ix, Lazy, [FIXTURE_C]; env = ("FIXTUREC_HANG" => "1",))
        timedwait(() -> occursin("indexing $(FIXTURE_C.uuid)", log_of(pending.path)), INDEXER_WAIT_S) === :ok ||
            error("indexer never announced FixtureC within $INDEXER_WAIT_S s; log:\n", log_of(pending.path))
        @test !IndexerExt.start_indexing!(ix, Lazy, WS.member, pending.path, wanted([FIXTURE_C]), _ -> nothing)
        # The indexing lock holds the subprocess's pid.
        pid = parse(Int, first(split(read(pending.path * ".indexing", String))))
        # Julia 1.12 segfaults on SIGINT with `exit_on_sigint(false)`, which then counts as a crash.
        signal = VERSION >= v"1.13" ? "INT" : "TERM"
        run(`kill -$signal $pid`)
        (; path, changed) = finish_run(pending)
        @test !changed
        @test isempty(read_catalog(path))
    end
    @testset "a hung package times out" begin
        (; path, changed) = run_indexer(IndexerExt.Indexer(; timeout_s = 8), Lazy, [FIXTURE_C];
                                        env = ("FIXTUREC_HANG" => "1",))
        @test changed
        @test failure_of(path, FIXTURE_C) ==
            PkgFailure(FIXTURE_C, v"0.1.0", "indexer timed out after 8 s while indexing")
        @test !ispath(path * ".indexing")  # released for the next run despite SIGKILL
    end
    @testset "on_exit may start the next run" begin
        start(ids, on_exit) = withenv("JULIA_DEPOT_PATH" => WS.depot_path, "JULIA_LOAD_PATH" => nothing) do
            IndexerExt.start_indexing!(ix, Lazy, WS.member, joinpath(mktempdir(), "catalog-v1"), wanted(ids), on_exit)
        end
        results = Channel{Any}(2)
        @test start([FIXTURE_A], _ -> put!(results, start([FIXTURE_C], _ -> put!(results, :second_done))))
        next_result() = timedwait(() -> isready(results), INDEXER_WAIT_S) === :ok ? take!(results) : :timed_out
        restarted = next_result()
        @test restarted === true
        restarted === true && @test next_result() === :second_done
    end
    @testset "nothing to index starts nothing" begin
        @test !IndexerExt.start_indexing!(ix, Lazy, WS.member, joinpath(mktempdir(), "catalog-v1"),
                                          wanted(Base.PkgId[]), _ -> error("on_exit must not run"))
    end
    @testset "a recurring supervisor failure is logged once" begin
        dir = mktempdir()
        chmod(dir, 0o555)  # the indexer log cannot be opened
        logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
        try
            Base.CoreLogging.with_logger(logger) do
                foreach(_ -> finish_run(start_run(ix, Lazy, [FIXTURE_A]; path = joinpath(dir, "catalog-v1"))), 1:2)
            end
        finally
            chmod(dir, 0o755)
        end
        @test count(log -> startswith(log.message, "Supervising the indexer"), logger.logs) == 1
    end
    @testset "a held indexing lock stops the run" begin
        path = joinpath(mktempdir(), "catalog-v1")
        lock = Base.invokelatest(PIDFILE.mkpidlock, path * ".indexing")
        try
            (; changed) = finish_run(start_run(ix, Lazy, [FIXTURE_A]; path))
            @test !changed
            @test !isfile(path)
            @test !occursin("indexing", log_of(path))
        finally
            close(lock)
        end
    end
end

end
