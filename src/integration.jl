# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Loads the REPL extension once the first prompt is up, on the REPL's
# evaluation thread: loading packages from two threads at once crashes Julia 1.13.

const REPL_ID = Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL")
const STYLEDSTRINGS_ID = Base.PkgId(Base.UUID("f489334b-da3d-4c2e-b8f0-e476e12c162b"), "StyledStrings")
# The extension's last trigger: a stdlib nothing else loads, used as a latch.
const LATCH_ID = Base.PkgId(Base.UUID("9fa8497b-333b-5362-9e8d-4d0656e87820"), "Future")
const PROMPT_POLL_S = 0.02

"""
    LazyIntegration(loading, repl)

Runs `loading` at `repl`'s first prompt (as a polling `Timer`'s callback) or
its first input (as an AST transform), whichever comes first.
"""
struct LazyIntegration <: Function
    loading::Task
    repl::Any
end

function (lazy::LazyIntegration)(timer::Timer)
    (; repl) = lazy
    # Builtins, as `hasproperty` would compile for the REPL's type.
    isdefined(repl, :mistate) && getfield(repl, :mistate) === nothing && return
    close(timer)
    finish(lazy.loading)
end

(lazy::LazyIntegration)(@nospecialize(ex)) = (finish(lazy.loading); ex)

function __init__()
    isinteractive() || return
    if isdefined(Base, :active_repl)
        errormonitor(schedule(Task(loadintegration)))
    else
        atreplinit(deferintegration)
    end
    nothing
end

# The running REPL, and on 1.12 the StyledStrings it uses, only count as loaded, and so trigger the extension,
# once required.
loadintegration() = (Base.require(REPL_ID); Base.require(STYLEDSTRINGS_ID); Base.require(LATCH_ID))

# An `atreplinit` hook: the REPL's backend copies `repl_ast_transforms` afterwards.
function deferintegration(@nospecialize(repl))
    lazy = LazyIntegration(errormonitor(Task(loadintegration)), repl)
    push!(parentmodule(typeof(repl)).repl_ast_transforms, lazy)
    Timer(lazy, PROMPT_POLL_S; interval = PROMPT_POLL_S)
    nothing
end

function finish(loading::Task)
    istaskstarted(loading) || schedule(loading)
    wait(loading; throw = false)
end

precompile(__init__, ())
precompile(loadintegration, ())
precompile(deferintegration, (Any,))
precompile(finish, (Task,))
precompile(Tuple{LazyIntegration, Timer})
precompile(Tuple{LazyIntegration, Expr})
