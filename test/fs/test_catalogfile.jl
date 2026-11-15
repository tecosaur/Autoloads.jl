using Test
using Autoloads: CatalogRecord, PkgNames, PkgFailure, catalog_line, read_catalog, write_catalog_changes!

const CATALOG_UUID_A = Base.UUID("00000000-0000-0000-0000-0000000000b1")
const CATALOG_UUID_B = Base.UUID("00000000-0000-0000-0000-0000000000b2")

catalog_names(uuid, name, version, exported...) =
    PkgNames(Base.PkgId(uuid, name), [version], Set(Symbol.(exported)), Set{Symbol}(), Set{Symbol}())

@testset "catalog file" begin
    @testset "read and write" begin
        mktempdir() do dir
            path = joinpath(dir, "sub", "catalog-v1")
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

    @testset "torn catalog" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog-v1")
            good = catalog_names(CATALOG_UUID_A, "A", v"1.0.0", :A)
            line = catalog_line(catalog_names(CATALOG_UUID_B, "B", v"1.0.0", :B, :h))
            write(path, catalog_line(good) * "\n" * line[1:end-12])
            records = @test_logs (:warn, r"1 malformed") read_catalog(path)
            @test records == [good]
        end
    end

    @testset "concurrent writers" begin
        mktempdir() do dir
            path = joinpath(dir, "catalog-v1")
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
