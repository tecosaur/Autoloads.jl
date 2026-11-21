# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Precompile workload: what inputs and the worker's first refresh run.

ccall(:jl_tag_newly_inferred_enable, Cvoid, ())  # as PrecompileTools does, to cache code dispatched to at run time
try
    let id = Base.PkgId(Base.UUID("0b1b2b3b-4444-4555-8666-777788889999"), "Workload")
        at = Sighting[(; version = v"1.0.0", julia = JULIA_MINOR)]
        records = CatalogRecord[PkgNames(id, at, Set([:Workload, :wl, Symbol("@wl")]), Set([:wp]), Set{Symbol}())]
        catalog = buildcatalog(records)
        cfg = parseconfig(Dict{String, Any}())
        autoload = Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => v"1.0.0")
        reg = buildregistry(catalog, autoload, cfg)
        env = (; deps = [id], graph = ManifestGraph())
        session = Session(cfg, "", env, nothing, env, catalog, autoload, reg)
        input = REPL.softscope(Base.parse_input_line("x = 1; y = [wl(x), Workload.wp(2)]; @wl f(z) = wl(z); wl"))
        transformstatements(session, input)
        for stmt in input.args[end].args
            statementmacros(stmt)
            helpquerynames(stmt)
            undefinedglobals(stmt, @__MODULE__)
        end
        help = REPL.helpmode(devnull, "Workload.wl(x)", @__MODULE__)
        statementmacros(help)
        helpquerynames(help)
        owner(reg, :wl)
        for (text, region) in (("wl", 0 => 2), ("Workload.w", 9 => 10))
            withautoloadable((LineEdit.NamedCompletion[LineEdit.NamedCompletion("w")], region, true), session, text)
        end
        precompile(Core.kwcall, (@NamedTuple{hint::Bool}, typeof(LineEdit.complete_line),
                                 CompletionWrapper{REPL.REPLCompletionProvider}, LineEdit.PromptState, Module))
        precompile(Tuple{ObserveLoad, Base.PkgId})
        precompile(repltransform, (Expr,))
        let runtime = Runtime(Channel{Event}(Inf), "", "")
            awaitfirstrefresh(runtime, 0)
            @atomic runtime.hasrefreshed = true
            transforminput(runtime, :(1))
        end
        precompile(Worker, (Runtime, Indexer))
        precompile(runworker, (Worker,))
        precompile(launchsupervised, (Cmd, String, String, Vector{Pair{Base.PkgId, Union{VersionNumber, Nothing}}}, Int, Set{String}))
        precompile(setproperty!, (Base.Process, Symbol, Base.DevNull))
        precompile(Core.kwcall, (@NamedTuple{throw::Bool}, typeof(wait), Task))
        mktempdir() do dir
            member = joinpath(dir, "autoloads")
            mkpath(member)
            write(joinpath(member, "Project.toml"), "[deps]\nWorkload = \"$(id.uuid)\"\n")
            writecatalog!(joinpath(dir, "catalog"),
                                   push!(copy(records), PkgFailure(id, Sighting[(; version = v"0.9.0", julia = JULIA_MINOR)], "failed")))
            parseconfig(Dict{String, Any}("project" => ["Workload"], "packages" => Dict{String, Any}(
                "Workload" => Dict{String, Any}("skip" => ["wl"], "only" => ["wp"], "bindings" => "used"))))
            worker = Worker(Runtime(Channel{Event}(Inf), member, joinpath(dir, "catalog")), Indexer())
            # The user's settings are read, and may not suit this member; their state is not.
            withenv("XDG_STATE_HOME" => dir) do
                Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    derivesession(worker)
                    maintainenvironment!(worker)
                    observe!(worker, [Base.PkgId(Autoloads)])
                end
            end
            providerhint(:wl, catalog, member)
        end
        precompile(undefvarhint, (IO, UndefVarError))
        precompile(preparestatement, (Expr,))
        precompile(preparestatement, (Symbol,))
        precompile(wrapcompletion!, (REPL.LineEditREPL,))
        precompile(Tuple{Type{CompletionWrapper}, REPL.REPLCompletionProvider})
        precompile(loadpending!, (Session, Vector{Symbol}))
        # `LoadState.attempted` keys are concrete tuples at run time.
        for key in (Tuple{Base.PkgId, Nothing}, Tuple{Base.PkgId, Symbol})
            precompile(in, (key, Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}))
            precompile(push!, (Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}, key))
        end
    end
finally
    ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
end
