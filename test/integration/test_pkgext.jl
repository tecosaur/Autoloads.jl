# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A module keeps these helpers apart from the other test files' globals.
module TestPkgExt

using Test, Pkg, REPL, Autoloads

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
function withnotifications(body)
    savedspecs = copy(PACKAGE_SPECS)
    savedhook = Autoloads.ENV_CHANGED[]
    notified = Ref(0)
    Autoloads.ENV_CHANGED[] = () -> notified[] += 1
    try
        body(notified)
    finally
        Autoloads.ENV_CHANGED[] = savedhook
        merge!(empty!(PACKAGE_SPECS), savedspecs)
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
        @test parsed("autoloads st FixtureA FixtureB") == (Autoloads.status, "FixtureA", "FixtureB")
        @test parsed("autoloads init") == (Autoloads.init,)
        @test parsed("autoloads add FixtureA")[2] isa Vector{String}
        @test parsed("autoloads rm FixtureA")[2] isa Vector{String}
        @test parsed("autoloads up")[2] isa Vector{String}
    end
    @testset "invalid input" begin
        @test_throws Pkg.Types.PkgError parsed("autoloads frob")
        @test_throws Pkg.Types.PkgError parsed("autoloads add")
        @test_throws Pkg.Types.PkgError parsed("autoloads init x")
    end
    @testset "rm and up complete the packages they act on" begin
        complete(input) = first(Base.get_extension(Pkg, :REPLExt).completions(input, lastindex(input)))
        globalenv = joinpath(mktempdir(), "environments", "v$(VERSION.major).$(VERSION.minor)")
        write(joinpath(mkpath(joinpath(globalenv, "autoloads")), "Project.toml"),
              "[deps]\nMemberDep = \"$(Base.UUID(UInt128(2)))\"\n")
        write(joinpath(globalenv, "Project.toml"), "[deps]\nGlobalDep = \"$(Base.UUID(UInt128(1)))\"\n")
        saved = copy(DEPOT_PATH)
        copy!(DEPOT_PATH, [dirname(dirname(globalenv))])
        try
            @test complete("autoloads rm Mem") == ["MemberDep"]
            @test isempty(complete("autoloads rm Glob"))
            @test complete("autoloads up Glob") == ["GlobalDep"]
            @test complete("autoloads up Mem") == ["MemberDep"]
        finally
            copy!(DEPOT_PATH, saved)
        end
    end
    @testset "status completes autoload packages" begin
        complete(input) = first(Base.get_extension(Pkg, :REPLExt).completions(input, lastindex(input)))
        @test complete("autoloads st Base6") == ["Base64"]
        @test complete("autoloads status Pkg Rand") == ["Random"]
        @test isempty(complete("autoloads st NoSuchPack"))
    end
    @testset "help lists the group" begin
        help = sprint(show, MIME("text/plain"), Pkg.REPLMode.help)
        @test all(cmd -> occursin("autoloads $cmd", help), ("add", "init", "remove", "status", "update"))
    end
    @testset "refreshing commands request a refresh" begin
        for name in Ext.REFRESHING_COMMANDS
            @test PACKAGE_SPECS[name].api isa Ext.RefreshingApi
        end
        @test PACKAGE_SPECS["up"] === PACKAGE_SPECS["update"]
        @test PACKAGE_SPECS["rm"] === PACKAGE_SPECS["remove"]
        @test parsed("up")[1] isa Ext.RefreshingApi
        @test parsed("update")[1] isa Ext.RefreshingApi
        @test !(PACKAGE_SPECS["activate"].api isa Ext.RefreshingApi)
        withnotifications() do notified
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
    @testset "up includes the autoloads when the global environment is active" begin
        withnotifications() do _
            workspace, spec, active = Ref(false), PACKAGE_SPECS["up"], Base.active_project()
            fake = (args...; kwargs...) -> workspace[] = kwargs[:workspace]
            PACKAGE_SPECS["up"] = Pkg.REPLMode.CommandSpec((if f === :api fake else getfield(spec, f) end
                                                           for f in fieldnames(Pkg.REPLMode.CommandSpec))...)
            Ext.wrappkgcommands!()
            try
                Base.set_active_project(joinpath(mktempdir(), "Project.toml"))
                PACKAGE_SPECS["up"].api()
                @test !workspace[]
                Base.set_active_project(joinpath(Autoloads.globalenvdir(), "Project.toml"))
                PACKAGE_SPECS["up"].api()
                @test workspace[]
                @testset "but not when the settings are invalid" begin
                    depot = mktempdir()
                    # Created first, so that `globalenvdir` picks it over the user's.
                    globalproject = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
                    mkpath(dirname(globalproject))
                    write(globalproject, """
                        [deps]
                        Autoloads = "$(Base.PkgId(Autoloads).uuid)"

                        [preferences.Autoloads]
                        uphook = "no"
                        """)
                    pushfirst!(DEPOT_PATH, depot)
                    try
                        Base.set_active_project(globalproject)
                        @test_logs (:warn, r"settings are invalid") PACKAGE_SPECS["up"].api()
                        @test !workspace[]
                    finally
                        popfirst!(DEPOT_PATH)
                    end
                end
            finally
                Base.set_active_project(active)
            end
        end
    end
    @testset "wrapping is idempotent and coexists with other wrappers" begin
        withnotifications() do notified
            before = PACKAGE_SPECS["up"]
            Ext.wrappkgcommands!()
            @test PACKAGE_SPECS["up"] === before
            @test !(PACKAGE_SPECS["up"].api.api isa Ext.RefreshingApi)
            for name in ("activate", "add")
                thirdpartycalls = Ref(0)
                thirdparty = (args...; kwargs...) -> (thirdpartycalls[] += 1; nothing)
                spec = PACKAGE_SPECS[name]
                PACKAGE_SPECS[name] = Pkg.REPLMode.CommandSpec((if f === :api thirdparty else getfield(spec, f) end
                                                               for f in fieldnames(Pkg.REPLMode.CommandSpec))...)
                Ext.wrappkgcommands!()
                api = PACKAGE_SPECS[name].api
                api()
                @test thirdpartycalls[] == 1
                @test if name == "activate" api === thirdparty else api isa Ext.RefreshingApi && notified[] == 1 end
            end
        end
    end
    @testset "an unrecognised Pkg layout warns, wraps nothing and keeps the help" begin
        withnotifications() do _
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
