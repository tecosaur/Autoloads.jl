using Test

# Pure tests, then filesystem tests, then integration tests.
@testset "Autoloads" begin
    for dir in ("", "fs", "integration")
        path = joinpath(@__DIR__, dir)
        isdir(path) || continue
        for file in sort(readdir(path))
            startswith(file, "test_") && endswith(file, ".jl") && include(joinpath(path, file))
        end
    end
end
