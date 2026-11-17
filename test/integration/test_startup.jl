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

# A session autoloading three modules of Base, which load without compiling, a package that is not installed, and
# REPL, sharing a name with it.
const SESSION_SETUP = """
    using Autoloads, REPL, Future
    using Autoloads: PkgNames, CatalogRecord, build_catalog, build_registry, parse_config
    const Ext = Base.get_extension(Autoloads, :AutoloadsREPLExt)
    origin = Base.PkgId(Base.UUID(UInt128(2)), "Origin")
    names(id, exported...; shared = Symbol[]) = PkgNames(id, VersionNumber[], Set(exported), Set{Symbol}(), Set(shared);
                                                         origins = Dict(name => origin for name in shared))
    records = CatalogRecord[names(Base.PkgId(Base.UUID(UInt128(1)), "Stranger"), :Stranger, :stranger_fn; shared = [:LineEditREPL]),
                            names(Base.PkgId(REPL), :REPL; shared = [:LineEditREPL]),
                            names(Base.PkgId(nothing, "Base.Threads"), :Threads, :nthreads),
                            names(Base.PkgId(nothing, "Base.Iterators"), :Iterators, :flatten),
                            names(Base.PkgId(nothing, "Base.Meta"), :Meta, :quot)]
    catalog, cfg = build_catalog(records), parse_config(Dict{String, Any}())
    autoload = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(record.id => nothing for record in records)
    const SESSION = Ext.Session(catalog, build_registry(catalog, autoload, cfg), cfg, mktempdir(), Set{String}())
    @atomic Ext.SESSION.session = SESSION
    """

const SESSION_SCRIPT = SESSION_SETUP * """
    Ext.RUNTIME[] = Ext.Runtime(Channel{Ext.Event}(Inf), "", "")
    @atomic Ext.RUNTIME[].has_refreshed = true
    inputs = [REPL.softscope(Base.parse_input_line("nthreads")), REPL.softscope(REPL.helpmode(devnull, "flatten", Main)),
              REPL.softscope(Base.parse_input_line("x = quot(1)")), REPL.softscope(Base.parse_input_line("LineEditREPL"))]
    completions = [(REPL.LineEdit.NamedCompletion[], region, true) => text
                   for (text, region) in ("nthr" => (0 => 4), "Stranger.str" => (9 => 12))]
    println(stderr, "START")
    completed = [Ext.with_autoloadable(result, SESSION, text) for (result, text) in completions]
    foreach(input -> Core.eval(Main, Ext.repl_transform(input)), inputs)
    println(stderr, "END")
    print(stderr, "RAN: ", all(name -> isdefined(Main, name), (:nthreads, :flatten, :quot, :LineEditREPL)) &&
                           all(c -> length(first(c)) == 1, completed))
    """

# The REPL shows errors on an `IOContext` over its terminal: an IO type the workload has not seen.
const HINT_SCRIPT = SESSION_SETUP * """
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

@testset "autoloading inputs, help queries and completions compile nothing of Autoloads'" begin
    traced, rest = traced_compilation(SESSION_SCRIPT)
    @test !occursin("Autoloads", traced)
    @test endswith(rest, "RAN: true")
end

@testset "the first UndefVarError hint compiles nothing of Autoloads'" begin
    traced, rest = traced_compilation(HINT_SCRIPT)
    @test !occursin("Autoloads", traced)
    @test endswith(rest, "HINTED: true")
end

end
