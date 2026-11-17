# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Precompile workload: what inputs and the worker's first refresh run. Tagged as
# PrecompileTools does, to also cache what is dispatched to dynamically.

ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
try
    let id = Base.PkgId(Base.UUID("0b1b2b3b-4444-4555-8666-777788889999"), "Workload")
        records = CatalogRecord[PkgNames(id, [v"1.0.0"], Set([:Workload, :wl, Symbol("@wl")]), Set([:wp]), Set{Symbol}())]
        catalog = build_catalog(records)
        cfg = parse_config(Dict{String, Any}())
        reg = build_registry(catalog, Dict{Base.PkgId, Union{VersionNumber, Nothing}}(id => v"1.0.0"), cfg)
        session = Session(catalog, reg, cfg, "", Set{String}())
        input = REPL.softscope(Base.parse_input_line("x = 1; y = [wl(x), Workload.wp(2)]; @wl f(z) = wl(z)"))
        transform_statements(session, input)
        for stmt in input.args[end].args
            statement_macros(stmt)
            undefined_globals(stmt, @__MODULE__)
        end
        owner(reg, :wl)
        for (text, region) in (("wl", 0 => 2), ("Workload.w", 9 => 10))
            with_autoloadable((LineEdit.NamedCompletion[LineEdit.NamedCompletion("w")], region, true), session, text)
        end
        precompile(Core.kwcall, (@NamedTuple{hint::Bool}, typeof(LineEdit.complete_line),
                                 CompletionWrapper{REPL.REPLCompletionProvider}, LineEdit.PromptState, Module))
        precompile(Tuple{ObserveLoad, Base.PkgId})
        precompile(repl_transform, (Expr,))
        let runtime = Runtime(Channel{Event}(Inf), "", "")
            await_first_refresh(runtime, 0)
            @atomic runtime.has_refreshed = true
            transform_input(runtime, :(1))
        end
        precompile(Worker, (Runtime, Indexer))
        precompile(run_worker, (Worker,))
        precompile(launch_and_supervise, (Cmd, String, String, Vector{Pair{Base.PkgId, Union{VersionNumber, Nothing}}}, Int, Set{String}))
        mktempdir() do dir
            member = joinpath(dir, "autoloads")
            mkpath(member)
            write(joinpath(member, "Project.toml"), "[deps]\nWorkload = \"$(id.uuid)\"\n")
            write_catalog_changes!(joinpath(dir, "catalog"), [records; PkgFailure(id, v"0.9.0", "failed")])
            parse_config(Dict{String, Any}("project" => ["Workload"], "packages" => Dict{String, Any}(
                "Workload" => Dict{String, Any}("skip" => ["wl"], "only" => ["wp"], "bindings" => "used"))))
            worker = Worker(Runtime(Channel{Event}(Inf), member, joinpath(dir, "catalog")), Indexer())
            # The user's settings are read, and may not suit this member.
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                derive_session(worker)
                maintain_environment!(worker)
                observe!(worker, [Base.PkgId(Autoloads)])
            end
        end
        precompile(prepare_statement, (Expr,))
        precompile(wrap_completion!, (REPL.LineEditREPL,))
        precompile(Tuple{Type{CompletionWrapper}, REPL.REPLCompletionProvider})
        precompile(load_pending!, (Session, Vector{Symbol}))
        # `LoadState.attempted` keys are concrete tuples at run time.
        for key in (Tuple{Base.PkgId, Nothing}, Tuple{Base.PkgId, Symbol})
            precompile(in, (key, Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}))
            precompile(push!, (Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}, key))
        end
    end
finally
    ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
end
