# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestIndexer

using Test, REPL, Future, Autoloads
using Autoloads: PkgNames, PkgFailure, readcatalog, manifestgraph, Lazy, Background

include("setup.jl")

"Sightings of `version` on this Julia minor."
here(version) = Autoloads.Sighting[(; version, julia = Autoloads.JULIA_MINOR)]

const IndexerExt = Base.get_extension(Autoloads, :AutoloadsREPLExt)
const PIDFILE = Base.require(Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")).Pidfile
const INDEXER_WAIT_S = 120

@testset "exit_failure" begin
    exitfailure = IndexerExt.exitfailure
    inprogress = FIXTURE_C => v"0.1.0"
    @test exitfailure(inprogress, 3, 0, false, 300) ==
        PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer exited with code 3 while indexing")
    @test exitfailure(inprogress, 0, 9, true, 300) ==
        PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer timed out after 300 s while indexing")
    @test exitfailure(FIXTURE_C => nothing, 1, 0, false, 300) ==
        PkgFailure(FIXTURE_C, here(nothing), "indexer exited with code 1 while indexing")
    @test exitfailure(inprogress, 0, 11, false, 300) ==
        PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer killed by signal 11 while indexing")  # segfault
    @test exitfailure(inprogress, 0, 9, false, 300) ==
        PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer killed by signal 9 while indexing")   # OOM killer
    @test exitfailure(inprogress, 0, 0, false, 300) === nothing   # finished normally
    @test exitfailure(inprogress, 0, 0, true, 300) === nothing    # timer fired as it finished
    @test exitfailure(inprogress, 0, 15, true, 300) === nothing   # stopped by someone else
    for signal in (2, 15, 1)                                        # SIGINT, SIGTERM, SIGHUP
        @test exitfailure(inprogress, 0, signal, false, 300) === nothing
    end
    @test exitfailure(inprogress, 130, 0, false, 300) === nothing # interrupted
    @test exitfailure(nothing, 3, 0, false, 300) === nothing       # before any package
    @test exitfailure(nothing, 0, 9, true, 300) === nothing
end

const WS = buildworkspace()
const GRAPH = manifestgraph(joinpath(WS.member, "Project.toml"))
const CACHE_DIR = joinpath(WS.depot, "compiled", "v$(VERSION.major).$(VERSION.minor)")

wanted(ids) = Pair{Base.PkgId, Union{VersionNumber, Nothing}}[id => GRAPH.versions[id.uuid] for id in ids]
recordsof(path, id) = filter(r -> r.id == id, readcatalog(path))
namesof(path, id) = only(filter(r -> r isa PkgNames, recordsof(path, id)))
failureof(path, id) = only(filter(r -> r isa PkgFailure, recordsof(path, id)))
logof(path) = isfile(path * ".log") ? read(path * ".log", String) : ""

"Start indexing `ids` into a fresh catalog; returns the catalog path and a channel receiving `changed`."
function startrun(ix, policy, ids; env = (), path = joinpath(mktempdir(), "catalog"))
    done = Channel{Bool}(1)
    started = withenv("JULIA_DEPOT_PATH" => WS.depotpath, "JULIA_LOAD_PATH" => nothing, env...) do
        IndexerExt.startindexing!(ix, policy, WS.member, path, wanted(ids), changed -> put!(done, changed))
    end
    @test started
    (; path, done)
end

function finishrun((; path, done))
    timedwait(() -> isready(done), INDEXER_WAIT_S) === :ok ||
        error("indexer for $path did not finish within $INDEXER_WAIT_S s; log:\n", logof(path))
    (; path, changed = take!(done))
end

runindexer(ix, policy, ids; env = ()) = finishrun(startrun(ix, policy, ids; env))

function checkfixtureanames(path)
    a = namesof(path, FIXTURE_A)
    @test a.at == here(v"0.1.0")
    @test a.exported == Set([:FixtureA, :fa, Symbol("@fam"), :FA_CONST])
    @test :fa_public in a.public
end

@testset "indexer" begin
    ix = IndexerExt.Indexer()
    @testset "lazy policy writes no caches" begin
        (; path, changed) = runindexer(ix, Lazy, [FIXTURE_A, FIXTURE_B])
        @test changed
        checkfixtureanames(path)
        b = namesof(path, FIXTURE_B)
        @test :fa in b.reexported && :fb in b.exported
        @test !isdir(joinpath(CACHE_DIR, "FixtureA"))
        @test occursin("indexing $(FIXTURE_A.uuid)", logof(path))
    end
    @testset "background policy precompiles; load failures are contained" begin
        (; path, changed) = runindexer(ix, Background, [FIXTURE_A, FIXTURE_B, FIXTURE_C];
                                        env = ("FIXTUREB_FAIL" => "1",))
        @test changed
        checkfixtureanames(path)
        failure = failureof(path, FIXTURE_B)
        @test failure.at == here(v"0.1.0") && occursin("FIXTUREB_FAIL", failure.message)
        @test :fc in namesof(path, FIXTURE_C).exported
        @test isdir(joinpath(CACHE_DIR, "FixtureA"))
        output = IOBuffer()
        check = "print(Base.isprecompiled(Base.PkgId(Base.UUID(\"$(FIXTURE_A.uuid)\"), \"FixtureA\")))"
        wait(runjulia(`-e $check`; project = WS.member, output,
                       env = ("JULIA_DEPOT_PATH" => WS.depotpath,)))
        @test String(take!(output)) == "true"
    end
    @testset "crash containment" begin
        (; path, changed) = runindexer(ix, Lazy, [FIXTURE_A, FIXTURE_C, FIXTURE_B];
                                        env = ("FIXTUREC_CRASH" => "1",))
        @test changed
        checkfixtureanames(path)
        @test failureof(path, FIXTURE_C) ==
            PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer exited with code 3 while indexing")
        @test isempty(recordsof(path, FIXTURE_B))
        @test !ispath(path * Autoloads.INDEXING_LOCK_SUFFIX)
    end
    @testset "a failed exit after the last package records no failure" begin
        (; path, changed) = runindexer(ix, Lazy, [FIXTURE_C]; env = ("FIXTUREC_EXIT_CRASH" => "1",))
        @test changed
        @test occursin("exited with code 3", logof(path))
        @test only(recordsof(path, FIXTURE_C)) isa PkgNames
    end
    @testset "one run at a time; an interrupted run records nothing" begin
        pending = startrun(ix, Lazy, [FIXTURE_C]; env = ("FIXTUREC_HANG" => "1",))
        timedwait(() -> occursin("indexing $(FIXTURE_C.uuid)", logof(pending.path)), INDEXER_WAIT_S) === :ok ||
            error("indexer never announced FixtureC within $INDEXER_WAIT_S s; log:\n", logof(pending.path))
        @test !IndexerExt.startindexing!(ix, Lazy, WS.member, pending.path, wanted([FIXTURE_C]), _ -> nothing)
        # The indexing lock holds the subprocess's pid.
        pid = parse(Int, first(split(read(pending.path * Autoloads.INDEXING_LOCK_SUFFIX, String))))
        # Julia 1.12 segfaults on SIGINT with `exit_on_sigint(false)`, which then counts as a crash.
        signal = VERSION >= v"1.13" ? "INT" : "TERM"
        run(`kill -$signal $pid`)
        (; path, changed) = finishrun(pending)
        @test !changed
        @test isempty(readcatalog(path))
    end
    @testset "a hung package times out" begin
        (; path, changed) = runindexer(IndexerExt.Indexer(; timeout_s = 8), Lazy, [FIXTURE_C];
                                        env = ("FIXTUREC_HANG" => "1",))
        @test changed
        @test failureof(path, FIXTURE_C) ==
            PkgFailure(FIXTURE_C, here(v"0.1.0"), "indexer timed out after 8 s while indexing")
        @test !ispath(path * Autoloads.INDEXING_LOCK_SUFFIX)  # released for the next run despite SIGKILL
    end
    @testset "onexit may start the next run" begin
        start(ids, onexit) = withenv("JULIA_DEPOT_PATH" => WS.depotpath, "JULIA_LOAD_PATH" => nothing) do
            IndexerExt.startindexing!(ix, Lazy, WS.member, joinpath(mktempdir(), "catalog"), wanted(ids), onexit)
        end
        results = Channel{Any}(2)
        @test start([FIXTURE_A], _ -> put!(results, start([FIXTURE_C], _ -> put!(results, :second_done))))
        nextresult() = timedwait(() -> isready(results), INDEXER_WAIT_S) === :ok ? take!(results) : :timedout
        restarted = nextresult()
        @test restarted === true
        restarted === true && @test nextresult() === :second_done
    end
    @testset "nothing to index starts nothing" begin
        @test !IndexerExt.startindexing!(ix, Lazy, WS.member, joinpath(mktempdir(), "catalog"),
                                          wanted(Base.PkgId[]), _ -> error("onexit must not run"))
    end
    @testset "a recurring supervisor failure is logged once" begin
        dir = mktempdir()
        chmod(dir, 0o555)  # the indexer log cannot be opened
        logger = Test.TestLogger(min_level = Base.CoreLogging.Error)
        try
            Base.CoreLogging.with_logger(logger) do
                foreach(_ -> finishrun(startrun(ix, Lazy, [FIXTURE_A]; path = joinpath(dir, "catalog"))), 1:2)
            end
        finally
            chmod(dir, 0o755)
        end
        @test count(log -> startswith(log.message, "Supervising the indexer"), logger.logs) == 1
    end
    @testset "a held indexing lock stops the run" begin
        path = joinpath(mktempdir(), "catalog")
        lock = Base.invokelatest(PIDFILE.mkpidlock, path * Autoloads.INDEXING_LOCK_SUFFIX)
        try
            (; changed) = finishrun(startrun(ix, Lazy, [FIXTURE_A]; path))
            @test !changed
            @test !isfile(path)
            @test !occursin("indexing", logof(path))
        finally
            close(lock)
        end
    end
end

end
