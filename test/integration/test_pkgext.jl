# A module keeps these helpers apart from the other test files' globals.
module TestPkgExt

using Test, Pkg, Autoloads

"The `(api, arguments...)` the Pkg REPL would call for `input`."
function parsed(input)
    Pkg.REPLMode.TEST_MODE[] = true
    try
        api, rest... = only(Pkg.REPLMode.pkgstr(input))
        (api, rest[1:end-1]...)
    finally
        Pkg.REPLMode.TEST_MODE[] = false
    end
end

@testset "pkg> autoloads" begin
    @testset "commands reach the management functions" begin
        @test parsed("autoloads add FixtureA ./dir") == (Autoloads.add, ["FixtureA", "./dir"])
        @test parsed("autoloads rm FixtureA") == (Autoloads.remove, ["FixtureA"])
        @test parsed("autoloads remove FixtureA FixtureB") == (Autoloads.remove, ["FixtureA", "FixtureB"])
        @test parsed("autoloads up") == (Autoloads.update, String[])
        @test parsed("autoloads update FixtureA") == (Autoloads.update, ["FixtureA"])
        @test parsed("autoloads st") == (Autoloads.status,)
        @test parsed("autoloads status") == (Autoloads.status,)
        @test parsed("autoloads init") == (Autoloads.init,)
        @test parsed("autoloads add FixtureA")[2] isa Vector{String}
        @test parsed("autoloads rm FixtureA")[2] isa Vector{String}
        @test parsed("autoloads up")[2] isa Vector{String}
    end
    @testset "invalid input" begin
        @test_throws Pkg.Types.PkgError parsed("autoloads frob")
        @test_throws Pkg.Types.PkgError parsed("autoloads add")
        @test_throws Pkg.Types.PkgError parsed("autoloads init x")
        @test_throws Pkg.Types.PkgError parsed("autoloads st x")
    end
    @testset "help lists the group" begin
        help = sprint(show, MIME("text/plain"), Pkg.REPLMode.help)
        @test all(cmd -> occursin("autoloads $cmd", help), ("add", "init", "remove", "status", "update"))
    end
end

end
