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

@testset "inputs compile nothing of Autoloads'" begin
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    # Not `Base.julia_cmd()`: `Pkg.test`'s flags (`--check-bounds=yes`) select other caches.
    cmd = `$julia --startup-file=no --project=$(Base.active_project()) --trace-compile=stderr -e $SCRIPT`
    trace = IOBuffer()
    run(pipeline(cmd; stdout = devnull, stderr = trace))
    output = String(take!(trace))
    @test occursin("START\n", output) && occursin("END\n", output)
    traced = first(split(last(split(output, "START\n")), "END\n"))
    @test !occursin("Autoloads", traced)
end

end
