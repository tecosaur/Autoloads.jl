# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test, Autoloads
using Autoloads: CatalogRecord, PkgNames, PkgFailure, Sighting, JULIA_MINOR, CatalogTooNew, catalogline, readcatalog,
    writecatalog!, buildcatalog, clearfailures!, readhealedcatalog

const CATALOG_UUID_A = Base.UUID("00000000-0000-0000-0000-0000000000b1")
const CATALOG_UUID_B = Base.UUID("00000000-0000-0000-0000-0000000000b2")
const HEADER = Autoloads.CATALOG_HEADER * "\n"

"Sightings of `versions` on this Julia minor."
here(versions...) = Sighting[(; version, julia = JULIA_MINOR) for version in versions]

catalognames(uuid, name, version, exported...; julia = JULIA_MINOR) =
    PkgNames(Base.PkgId(uuid, name), Sighting[(; version, julia)], Set(Symbol.(exported)), Set{Symbol}(), Set{Symbol}())

@testset "catalog file" begin
    @testset "read and write" begin
        mktempdir() do dir
            path = joinpath(dir, "sub", "catalog")
            @test readcatalog(path) == []
            a1 = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A, :f)
            @test writecatalog!(path, CatalogRecord[a1])
            @test readcatalog(path) == [a1]
            # unchanged observation leaves the file untouched
            before = read(path)
            @test !writecatalog!(path, CatalogRecord[a1])
            @test read(path) == before
            # a new id is appended after the earlier bytes
            b1 = catalognames(CATALOG_UUID_B, "B", v"2.0.0", :B)
            @test writecatalog!(path, CatalogRecord[b1])
            @test read(path)[1:length(before)] == before
            @test readcatalog(path) == [a1, b1]
            # identical namespace at a new version rewrites into one line
            a2 = catalognames(CATALOG_UUID_A, "A", v"1.1.0", :A, :f)
            @test writecatalog!(path, CatalogRecord[a2])
            records = readcatalog(path)
            @test count(r -> r.id.uuid == CATALOG_UUID_A, records) == 1
            @test only(filter(r -> r.id.uuid == CATALOG_UUID_A, records)).at == here(v"1.0.0", v"1.1.0")
            @test b1 in records
            # changed names at a new version give a second line for the id
            a3 = catalognames(CATALOG_UUID_A, "A", v"1.2.0", :A, :g)
            @test writecatalog!(path, CatalogRecord[a3])
            @test count(r -> r.id.uuid == CATALOG_UUID_A, readcatalog(path)) == 2
            @test !isfile(path * ".tmp-$(getpid())")
        end
    end

    @testset "Julia minors share the file" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            herea = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A, :f)
            oldera = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A, :f; julia = v"1.0")
            writecatalog!(path, CatalogRecord[herea])
            @test writecatalog!(path, CatalogRecord[oldera])
            @test only(readcatalog(path)).at == [only(oldera.at); only(herea.at)]
            failed = PkgFailure(Base.PkgId(CATALOG_UUID_A, "A"), oldera.at, "boom")
            @test writecatalog!(path, CatalogRecord[failed])
            @test Set(readcatalog(path)) == Set(CatalogRecord[herea, failed])
        end
    end

    @testset "clear failures" begin
        mktempdir() do dir
            path = joinpath(dir, "sub", "catalog")
            a, b = Base.PkgId(CATALOG_UUID_A, "A"), Base.PkgId(CATALOG_UUID_B, "B")
            @test !clearfailures!(path, [a])
            @test !ispath(dirname(path))
            a1 = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            failures = CatalogRecord[PkgFailure(a, here(v"1.1.0"), "boom"), PkgFailure(a, here(nothing), "?"),
                                     PkgFailure(b, here(v"2.0.0"), "bang")]
            writecatalog!(path, CatalogRecord[a1; failures])
            before = read(path)
            @test !clearfailures!(path, [Base.PkgId(CATALOG_UUID_A, "Other")])
            @test read(path) == before
            @test clearfailures!(path, [a])
            @test sort(readcatalog(path); by = catalogline) == sort([a1, failures[3]]; by = catalogline)
            @test clearfailures!(path, Set([b]))
            @test readcatalog(path) == [a1]
        end
    end
    @testset "rewrite round trip" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            a1 = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            fail = PkgFailure(Base.PkgId(CATALOG_UUID_A, "A"), here(v"3.0.0"), "boom")
            b1 = catalognames(CATALOG_UUID_B, "B", v"1.0.0", :B)
            @test writecatalog!(path, CatalogRecord[a1, fail, b1])
            @test writecatalog!(path, CatalogRecord[catalognames(CATALOG_UUID_A, "A", v"2.0.0", :A)])
            records = readcatalog(path)
            @test any(r -> r isa PkgNames && length(r.at) > 1, records)
            catalog = buildcatalog(records)
            @test Set(catalog.records[Base.PkgId(CATALOG_UUID_A, "A")]) ==
                Set(CatalogRecord[catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A) |>
                    r -> PkgNames(r.id, here(v"1.0.0", v"2.0.0"), r.exported, r.public, r.reexported), fail])
            @test catalog.records[Base.PkgId(CATALOG_UUID_B, "B")] == CatalogRecord[b1]
        end
    end

    @testset "append after a torn last line" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            line = catalogline(good)
            write(path, HEADER * line * "\n" * line[1:end-12])
            b1 = catalognames(CATALOG_UUID_B, "B", v"1.0.0", :B)
            @test (@test_logs (:warn, r"Removed 1 catalog line") writecatalog!(path, CatalogRecord[b1]))
            records = @test_logs readcatalog(path)
            @test sort(records; by = r -> r.id.name) == [good, b1]
        end
    end

    @testset "rejected record leaves the file untouched" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            bad = catalognames(CATALOG_UUID_B, "B", v"1.0.0", Symbol("has space"))
            @test_throws ArgumentError writecatalog!(path, CatalogRecord[good, bad])
            @test !isfile(path) || filesize(path) == 0
            writecatalog!(path, CatalogRecord[good])
            before = read(path)
            @test_throws ArgumentError writecatalog!(path, CatalogRecord[catalognames(CATALOG_UUID_A, "A", v"1.5.0", :A, Symbol("x y"))])
            @test read(path) == before
            @test isempty(filter(contains(".tmp-"), readdir(dir)))
        end
    end

    @testset "another format" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            for header in ("", "Autoloads catalog v0\n")
                write(path, header * catalogline(good) * "\n")
                @test isempty(@test_logs readcatalog(path))
                @test isempty(@test_logs (:warn, r"Removed \d catalog line") readhealedcatalog(path))
                @test read(path, String) == HEADER
                @test writecatalog!(path, CatalogRecord[good])
                @test readcatalog(path) == [good] && startswith(read(path, String), HEADER)
            end
        end
    end

    @testset "a newer format is left untouched" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            content = "Autoloads catalog v$(Autoloads.CATALOG_FORMAT + 1)\nnot this format's line\n"
            write(path, content)
            record = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            for operation in (() -> readcatalog(path), () -> readhealedcatalog(path),
                              () -> writecatalog!(path, CatalogRecord[record]),
                              () -> clearfailures!(path, [record.id]))
                @test_throws CatalogTooNew operation()
            end
            @test read(path, String) == content
            @test occursin("Update Autoloads", sprint(showerror, CatalogTooNew(path, 3)))
        end
    end

    @testset "torn catalog" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalognames(CATALOG_UUID_A, "A", v"1.0.0", :A)
            line = catalogline(catalognames(CATALOG_UUID_B, "B", v"1.0.0", :B, :h))
            write(path, HEADER * catalogline(good) * "\n" * line[1:end-12])
            @test (@test_logs readcatalog(path)) == [good]
            records = @test_logs (:warn, r"Removed 1 catalog line") readhealedcatalog(path)
            @test records == [good]
            @test (@test_logs readhealedcatalog(path)) == [good]
            @test !writecatalog!(path, CatalogRecord[good])
            # In a read-only directory the lines stay, and the warning is not repeated.
            write(path, HEADER * catalogline(good) * "\n" * line[1:end-12])
            chmod(dir, 0o555)
            try
                logger = Test.TestLogger(; respect_maxlog = true)
                reads = Base.CoreLogging.with_logger(() -> [readhealedcatalog(path) for _ in 1:2], logger)
                @test reads == [[good], [good]]
                @test occursin("could not be removed", only(logger.logs).message)
            finally
                chmod(dir, 0o755)
            end
        end
    end

    @testset "concurrent writers" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            script = joinpath(dir, "writer.jl")
            src = joinpath(pkgdir(Autoloads), "src")
            write(script, """
                include($(repr(joinpath(src, "records.jl"))))
                include($(repr(joinpath(src, "catalogfile.jl"))))
                worker, path = parse(Int, ARGS[1]), ARGS[2]
                for k in 1:100
                    uuid = iseven(k) ? Base.UUID(UInt128(worker * 1000 + k)) : Base.UUID(UInt128(k % 5 + 1))
                    version = VersionNumber(worker, k)
                    names = Set([Symbol("n_", worker, "_", k)])
                    at = Sighting[(; version, julia = JULIA_MINOR)]
                    writecatalog!(path, CatalogRecord[PkgNames(
                        Base.PkgId(uuid, "P"), at, names, Set{Symbol}(), Set{Symbol}())])
                end
                """)
            julia = Base.julia_cmd()
            procs = [run(pipeline(`$julia --startup-file=no $script $worker $path`; stderr), wait = false)
                     for worker in 1:2]
            @test all(success, procs)
            records = readcatalog(path)
            for worker in 1:2, k in 1:100
                uuid = iseven(k) ? Base.UUID(UInt128(worker * 1000 + k)) : Base.UUID(UInt128(k % 5 + 1))
                name = Symbol("n_", worker, "_", k)
                @test any(r -> r.id.uuid == uuid && any(s -> s.version == VersionNumber(worker, k), r.at) &&
                               r.exported == Set([name]), records)
            end
        end
    end
end
