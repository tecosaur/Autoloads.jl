# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module TestStartup

using Test

# Anything compiling on the REPL's thread adds input latency.
const SCRIPT = """
    using Autoloads, REPL, Future
    const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
    Ext.RUNTIME[] = Ext.Runtime(Channel{Ext.Event}(Inf), "", "")
    println(stderr, "START")
    foreach(_ -> Ext.repl_transform(REPL.softscope(Base.parse_input_line("x = 1; y = x + 1"))), 1:2)
    println(stderr, "END")
    """

# The REPL shows errors on an `IOContext` over its terminal: an IO type the workload has not seen.
const HINT_SCRIPT = """
    using Autoloads, REPL, Future
    using Autoloads: PkgNames, CatalogRecord, build_catalog, build_registry, parse_config
    const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
    records = CatalogRecord[PkgNames(Base.PkgId(Base.UUID(UInt128(1)), "Stranger"), [v"1.0.0"],
                                     Set([:Stranger, :stranger_fn]), Set{Symbol}(), Set{Symbol}())]
    catalog, cfg = build_catalog(records), parse_config(Dict{String, Any}())
    registry = build_registry(catalog, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(), cfg)
    @atomic Ext.SESSION.session = Ext.Session(catalog, registry, cfg, mktempdir(), Set{String}())
    io = IOContext(IOContext(devnull, :color => true), :limit => true)
    errors = [UndefVarError(name, Main) for name in (:stranger_fn, :no_such_name)]
    println(stderr, "START")
    foreach(err -> Ext.undefvar_hint(io, err), errors)
    println(stderr, "END")
    hint = sprint(Ext.undefvar_hint, first(errors))
    print(stderr, "HINTED: ", occursin("pkg> add Stranger", hint))
    """

"The `--trace-compile` output of `script` between its `START` and `END` lines, and what follows them."
function traced_compilation(script)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    # Not `Base.julia_cmd()`: `Pkg.test`'s flags (`--check-bounds=yes`) select other caches.
    cmd = `$julia --startup-file=no --project=$(Base.active_project()) --trace-compile=stderr -e $script`
    trace = IOBuffer()
    run(pipeline(cmd; stdout = devnull, stderr = trace))
    output = String(take!(trace))
    occursin("START\n", output) && occursin("END\n", output) ||
        error("The traced script did not run to its end:\n", output)
    split(last(split(output, "START\n")), "END\n")
end

@testset "inputs compile nothing of Autoloads'" begin
    @test !occursin("Autoloads", first(traced_compilation(SCRIPT)))
end

@testset "the first UndefVarError hint compiles nothing of Autoloads'" begin
    traced, rest = traced_compilation(HINT_SCRIPT)
    @test !occursin("Autoloads", traced)
    @test endswith(rest, "HINTED: true")
end

end
