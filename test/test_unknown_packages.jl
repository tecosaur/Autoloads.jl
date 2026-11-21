# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module TestUnknownPackages

using Test, REPL, Future, Autoloads
using Autoloads: parseconfig

const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)

@testset "unknown package settings warn once" begin
    cfg = parseconfig(Dict{String, Any}("packages" => Dict{String, Any}(
        name => Dict{String, Any}() for name in ("X", "Nope", "Other"))))
    autoload(names...) = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(
        Base.PkgId(Base.UUID(UInt128(i)), name) => nothing for (i, name) in enumerate(names))
    warned(reported, available) =
        [log.message for log in first(Test.collect_test_logs(() -> Ext.warnunknown!(reported, cfg, available)))]
    reported = Set{String}()
    @test contains(only(warned(reported, autoload("X"))), "does not autoload here: Nope, Other.")
    @test isempty(warned(reported, autoload("X")))
    @test isempty(warned(reported, autoload("X", "Nope", "Other")))
    @test contains(only(warned(reported, autoload("Other"))), "here: X.")
    # As when switching back and forth between projects.
    @test isempty(warned(reported, autoload("X")))
    @test isempty(warned(reported, autoload("Other")))
end

end
