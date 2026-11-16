# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Loading the REPL integration (the `AutoloadsREPLExt` extension) lazily: its
# image takes ~20 ms to load, so instead of loading with REPL, before the first
# prompt, it loads once the prompt is up. It loads on the task's own thread (the
# REPL's evaluation thread, not the one drawing the prompt): loading packages
# from two threads at once crashes Julia 1.13.

# A stdlib nothing else loads, used as a latch: the extension's triggers are
# REPL and this, so loading it is what loads the extension.
const LATCH_ID = Base.PkgId(Base.UUID("9fa8497b-333b-5362-9e8d-4d0656e87820"), "Future")
const PROMPT_POLL_S = 0.02

"""
    LazyIntegration(loading, repl)

Runs the `loading` task once `repl` is at its first prompt (as a polling
`Timer`'s callback), or when the first input arrives if that is sooner (as a
REPL AST transform, which the integration's own then follows).
"""
struct LazyIntegration <: Function
    loading::Task
    repl::Any
end

function (lazy::LazyIntegration)(timer::Timer)
    (; repl) = lazy
    hasproperty(repl, :mistate) && repl.mistate === nothing && return
    close(timer)
    finish(lazy.loading)
end

(lazy::LazyIntegration)(@nospecialize(ex)) = (finish(lazy.loading); ex)

function __init__()
    isinteractive() || return
    if isdefined(Base, :active_repl)
        errormonitor(schedule(Task(load_integration)))
    else
        atreplinit(defer_integration)
    end
    nothing
end

load_integration() = Base.require(LATCH_ID)

# An `atreplinit` hook: the REPL's backend copies `repl_ast_transforms` afterwards.
function defer_integration(@nospecialize(repl))
    lazy = LazyIntegration(errormonitor(Task(load_integration)), repl)
    push!(parentmodule(typeof(repl)).repl_ast_transforms, lazy)
    Timer(lazy, PROMPT_POLL_S; interval = PROMPT_POLL_S)
    nothing
end

function finish(loading::Task)
    istaskstarted(loading) || schedule(loading)
    wait(loading; throw = false)
end

precompile(__init__, ())
precompile(load_integration, ())
precompile(defer_integration, (Any,))
precompile(finish, (Task,))
precompile(Tuple{LazyIntegration, Timer})
precompile(Tuple{LazyIntegration, Expr})
