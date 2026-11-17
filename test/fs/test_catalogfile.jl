# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using Test, Autoloads
using Autoloads: CatalogRecord, PkgNames, PkgFailure, catalog_line, read_catalog, write_catalog_changes!, build_catalog,
    clear_failures!, read_healed_catalog

const CATALOG_UUID_A = Base.UUID("00000000-0000-0000-0000-0000000000b1")
const CATALOG_UUID_B = Base.UUID("00000000-0000-0000-0000-0000000000b2")
const HEADER = Autoloads.CATALOG_HEADER * "\n"

catalog_names(uuid, name, version, exported...) =
    PkgNames(Base.PkgId(uuid, name), [version], Set(Symbol.(exported)), Set{Symbol}(), Set{Symbol}())

@testset "catalog file" begin
    @testset "read and write" begin
        mktempdir() do dir
            path = joinpath(dir, "sub", "catalog")
            @test read_catalog(path) == []
            a1 = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A, :f)
            @test write_catalog_changes!(path, CatalogRecord[a1])
            @test read_catalog(path) == [a1]
            # unchanged observation leaves the file untouched
            before = read(path)
            @test !write_catalog_changes!(path, CatalogRecord[a1])
            @test read(path) == before
            # a new id is appended after the earlier bytes
            b1 = catalog_names(CATALOG_UUID_B, "B", v"2.0.0", :B)
            @test write_catalog_changes!(path, CatalogRecord[b1])
            @test read(path)[1:length(before)] == before
            @test read_catalog(path) == [a1, b1]
            # identical namespace at a new version rewrites into one line
            a2 = catalog_names(CATALOG_UUID_A, "A", v"1.1.0", :A, :f)
            @test write_catalog_changes!(path, CatalogRecord[a2])
            records = read_catalog(path)
            @test count(r -> r.id.uuid == CATALOG_UUID_A, records) == 1
            @test only(filter(r -> r.id.uuid == CATALOG_UUID_A, records)).versions == [v"1.0.0", v"1.1.0"]
            @test b1 in records
            # changed names at a new version give a second line for the id
            a3 = catalog_names(CATALOG_UUID_A, "A", v"1.2.0", :A, :g)
            @test write_catalog_changes!(path, CatalogRecord[a3])
            @test count(r -> r.id.uuid == CATALOG_UUID_A, read_catalog(path)) == 2
            @test !isfile(path * ".tmp-$(getpid())")
        end
    end

    @testset "clear failures" begin
        mktempdir() do dir
            path = joinpath(dir, "sub", "catalog")
            a, b = Base.PkgId(CATALOG_UUID_A, "A"), Base.PkgId(CATALOG_UUID_B, "B")
            @test !clear_failures!(path, [a])
            @test !ispath(dirname(path))
            a1 = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            failures = CatalogRecord[PkgFailure(a, v"1.1.0", "boom"), PkgFailure(a, nothing, "?"),
                                     PkgFailure(b, v"2.0.0", "bang")]
            write_catalog_changes!(path, CatalogRecord[a1; failures])
            before = read(path)
            @test !clear_failures!(path, [Base.PkgId(CATALOG_UUID_A, "Other")])
            @test read(path) == before
            @test clear_failures!(path, [a])
            @test sort(read_catalog(path); by = catalog_line) == sort([a1, failures[3]]; by = catalog_line)
            @test clear_failures!(path, Set([b]))
            @test read_catalog(path) == [a1]
        end
    end
    @testset "rewrite round trip" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            a1 = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            fail = PkgFailure(Base.PkgId(CATALOG_UUID_A, "A"), v"3.0.0", "boom")
            b1 = catalog_names(CATALOG_UUID_B, "B", v"1.0.0", :B)
            @test write_catalog_changes!(path, CatalogRecord[a1, fail, b1])
            @test write_catalog_changes!(path, CatalogRecord[catalog_names(CATALOG_UUID_A, "A", v"2.0.0", :A)])
            records = read_catalog(path)
            @test any(r -> r isa PkgNames && length(r.versions) > 1, records)
            catalog = build_catalog(records)
            @test Set(catalog.records[Base.PkgId(CATALOG_UUID_A, "A")]) ==
                Set(CatalogRecord[catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A) |>
                    r -> PkgNames(r.id, [v"1.0.0", v"2.0.0"], r.exported, r.public, r.reexported), fail])
            @test catalog.records[Base.PkgId(CATALOG_UUID_B, "B")] == CatalogRecord[b1]
        end
    end

    @testset "append after a torn last line" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            line = catalog_line(good)
            write(path, HEADER * line * "\n" * line[1:end-12])
            b1 = catalog_names(CATALOG_UUID_B, "B", v"1.0.0", :B)
            @test (@test_logs (:warn, r"Removed 1 catalog line") write_catalog_changes!(path, CatalogRecord[b1]))
            records = @test_logs read_catalog(path)
            @test sort(records; by = r -> r.id.name) == [good, b1]
        end
    end

    @testset "rejected record leaves the file untouched" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            bad = catalog_names(CATALOG_UUID_B, "B", v"1.0.0", Symbol("has space"))
            @test_throws ArgumentError write_catalog_changes!(path, CatalogRecord[good, bad])
            @test !isfile(path) || filesize(path) == 0
            write_catalog_changes!(path, CatalogRecord[good])
            before = read(path)
            @test_throws ArgumentError write_catalog_changes!(path, CatalogRecord[catalog_names(CATALOG_UUID_A, "A", v"1.5.0", :A, Symbol("x y"))])
            @test read(path) == before
            @test isempty(filter(contains(".tmp-"), readdir(dir)))
        end
    end

    @testset "another format" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            for header in ("", "Autoloads catalog v0\n")
                write(path, header * catalog_line(good) * "\n")
                @test isempty(@test_logs read_catalog(path))
                @test isempty(@test_logs (:warn, r"Removed \d catalog line") read_healed_catalog(path))
                @test read(path, String) == HEADER
                @test write_catalog_changes!(path, CatalogRecord[good])
                @test read_catalog(path) == [good] && startswith(read(path, String), HEADER)
            end
        end
    end

    @testset "torn catalog" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog")
            good = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            line = catalog_line(catalog_names(CATALOG_UUID_B, "B", v"1.0.0", :B, :h))
            write(path, HEADER * catalog_line(good) * "\n" * line[1:end-12])
            @test (@test_logs read_catalog(path)) == [good]
            records = @test_logs (:warn, r"Removed 1 catalog line") read_healed_catalog(path)
            @test records == [good]
            @test (@test_logs read_healed_catalog(path)) == [good]
            @test !write_catalog_changes!(path, CatalogRecord[good])
            # In a read-only directory the lines stay, and the warning is not repeated.
            write(path, HEADER * catalog_line(good) * "\n" * line[1:end-12])
            chmod(dir, 0o555)
            try
                logger = Test.TestLogger(; respect_maxlog = true)
                reads = Base.CoreLogging.with_logger(() -> [read_healed_catalog(path) for _ in 1:2], logger)
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
                    write_catalog_changes!(path, CatalogRecord[PkgNames(
                        Base.PkgId(uuid, "P"), [version], names, Set{Symbol}(), Set{Symbol}())])
                end
                """)
            julia = Base.julia_cmd()
            procs = [run(pipeline(`$julia --startup-file=no $script $worker $path`; stderr), wait = false)
                     for worker in 1:2]
            @test all(success, procs)
            records = read_catalog(path)
            for worker in 1:2, k in 1:100
                uuid = iseven(k) ? Base.UUID(UInt128(worker * 1000 + k)) : Base.UUID(UInt128(k % 5 + 1))
                name = Symbol("n_", worker, "_", k)
                @test any(r -> r.id.uuid == uuid && VersionNumber(worker, k) in r.versions &&
                               r.exported == Set([name]), records)
            end
        end
    end
end
