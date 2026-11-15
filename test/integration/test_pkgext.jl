# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

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

const Ext = Base.get_extension(Autoloads, :AutoloadsPkgExt)
const PACKAGE_SPECS = Pkg.REPLMode.SPECS["package"]

"Run `body(notified)` with `ENV_CHANGED` counting calls, restoring the package specs afterwards."
function with_notifications(body)
    saved_specs = copy(PACKAGE_SPECS)
    saved_hook = Autoloads.ENV_CHANGED[]
    notified = Ref(0)
    Autoloads.ENV_CHANGED[] = () -> notified[] += 1
    try
        body(notified)
    finally
        Autoloads.ENV_CHANGED[] = saved_hook
        merge!(empty!(PACKAGE_SPECS), saved_specs)
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
    @testset "environment-changing commands request a refresh" begin
        for name in Ext.ENV_CHANGING_COMMANDS
            @test PACKAGE_SPECS[name].api isa Ext.RefreshingApi
        end
        @test PACKAGE_SPECS["up"] === PACKAGE_SPECS["update"]
        @test PACKAGE_SPECS["rm"] === PACKAGE_SPECS["remove"]
        @test parsed("up")[1] isa Ext.RefreshingApi
        @test parsed("update")[1] isa Ext.RefreshingApi
        @test !(PACKAGE_SPECS["activate"].api isa Ext.RefreshingApi)
        with_notifications() do notified
            calls = []
            api = Ext.RefreshingApi((args...; kwargs...) -> (push!(calls, (args, kwargs)); :done))
            @test api(1, 2; key = 3) == :done
            @test calls == [((1, 2), pairs((; key = 3)))]
            @test notified[] == 1
            failing = Ext.RefreshingApi(() -> error("resolve failed"))
            @test_throws ErrorException failing()
            @test notified[] == 1
        end
    end
    @testset "wrapping is idempotent and coexists with other wrappers" begin
        with_notifications() do notified
            before = PACKAGE_SPECS["up"]
            Ext.wrap_pkg_commands!()
            @test PACKAGE_SPECS["up"] === before
            @test !(PACKAGE_SPECS["up"].api.api isa Ext.RefreshingApi)
            for name in ("activate", "add")
                third_party_calls = Ref(0)
                third_party = (args...; kwargs...) -> (third_party_calls[] += 1; nothing)
                spec = PACKAGE_SPECS[name]
                PACKAGE_SPECS[name] = Pkg.REPLMode.CommandSpec((f === :api ? third_party : getfield(spec, f)
                                                               for f in fieldnames(Pkg.REPLMode.CommandSpec))...)
                Ext.wrap_pkg_commands!()
                api = PACKAGE_SPECS[name].api
                api()
                @test third_party_calls[] == 1
                @test name == "activate" ? api === third_party : (api isa Ext.RefreshingApi && notified[] == 1)
            end
        end
    end
    @testset "an unrecognised Pkg layout warns, wraps nothing and keeps the help" begin
        with_notifications() do _
            delete!(PACKAGE_SPECS, "pin")
            snapshot = copy(PACKAGE_SPECS)
            @test_logs (:warn, r"cannot refresh") Ext.__init__()
            @test PACKAGE_SPECS == snapshot
            help = sprint(show, MIME("text/plain"), Pkg.REPLMode.help)
            @test occursin("autoloads init", help)
        end
    end
end

end
