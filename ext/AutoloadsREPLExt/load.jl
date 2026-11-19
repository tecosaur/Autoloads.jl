# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Loading into `Main`: from the active environment when it has the package, else
# with the member briefly on `LOAD_PATH`, after a version check.

"""
    LoadState()

The `(id, name)` loads tried this session (`name` is `nothing` for a whole
package), and the packages that failed, not retried until `forget_failures!`.
"""
struct LoadState
    attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}
    failed::Set{Base.PkgId}
end

LoadState() = LoadState(Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(), Set{Base.PkgId}())

"""
    load!(state, req, member; announce = true) -> Bool

Load `req` into `Main`: from the active environment if it has the package, else
from `member`, once the versions it would load agree with those loaded. Returns
whether it loaded; a failure is logged once, and not retried until
`forget_failures!`. An interrupt propagates and records nothing.
"""
function load!(state::LoadState, req::LoadRequest, member::AbstractString; announce::Bool = true)
    key = (req.id, req.name)
    req.id in state.failed && return (push!(state.attempted, key); false)
    announce && @info "Autoloading $(req.id.name) (for $(req.trigger))"
    loaded = try
        if is_in_current_env(req.id)
            Core.eval(Main, using_expr(req))
        else
            check_versions(req.id, member)
            with_member(member) do
                Base.locate_package(req.id) === nothing &&
                    error("$(req.id.name) is not installed in the autoloads environment; ",
                          "run `pkg> instantiate` with the global environment active to install it")
                Core.eval(Main, using_expr(req))
            end
        end
        true
    catch err
        is_interrupt(err) && throw(InterruptException())
        @warn "Failed to autoload $(req.id.name)" exception = (err, catch_backtrace())
        push!(state.failed, req.id)
        false
    end
    push!(state.attempted, key)
    loaded
end

function forget_failures!(state::LoadState)
    isempty(state.failed) && return
    filter!(((id, _),) -> id ∉ state.failed, state.attempted)
    empty!(state.failed)
    nothing
end

"""
    eval_with_member(stmt, member)

Evaluate `stmt` in `Main`, with `member` on `LOAD_PATH` while it does if `stmt`
imports a package only `member` provides, after `load!`'s version check.
"""
function eval_with_member(stmt, member::AbstractString)
    roots = member_only_roots(stmt)
    isempty(roots) && return Core.eval(Main, stmt)
    member_ids = project_deps(joinpath(member, "Project.toml"))
    for root in roots
        index = findfirst(id -> id.name == String(root), member_ids)
        index === nothing || check_versions(member_ids[index], member)
    end
    with_member(() -> Core.eval(Main, stmt), member)
end

# ── Helpers ──

# A Ctrl-C during a package's `__init__` or top level arrives wrapped.
is_interrupt(err) = err isa InterruptException ||
    (err isa Union{Base.InitError, LoadError} && is_interrupt(err.error))

is_in_current_env(id::Base.PkgId) = id.uuid === nothing || Base.identify_package(id.name) == id

function using_expr(req::LoadRequest)
    path = Expr(:., Symbol.(split(req.id.name, '.'))...)
    Expr(:using, if req.name === nothing path else Expr(:(:), path, Expr(:., req.name)) end)
end

function check_versions(id::Base.PkgId, member::AbstractString)
    graph = manifest_graph(joinpath(member, "Project.toml"))
    closure = dependency_closure(graph, id.uuid)
    loaded = @lock Base.require_lock [(pkg, mod) for (pkg, mod) in Base.loaded_modules if pkg.uuid in closure]
    conflicts = Tuple{String, VersionNumber, VersionNumber}[]
    for (pkg, mod) in loaded
        wanted = get(graph.versions, pkg.uuid, nothing)
        actual = pkgversion(mod)
        wanted === nothing || actual === nothing || actual == wanted ||
            push!(conflicts, (pkg.name, actual, wanted))
    end
    isempty(conflicts) && return
    differences = join(("$name v$loaded differs from v$wanted" for (name, loaded, wanted) in sort!(conflicts)), ", ")
    error("Not autoloading $(id.name): already-loaded $differences in the autoloads environment. ",
          "Add $(id.name) to the active project to load it there.")
end

function with_member(f, member::AbstractString)
    push!(LOAD_PATH, member)
    try
        f()
    finally
        index = findlast(==(member), LOAD_PATH)
        index === nothing || deleteat!(LOAD_PATH, index)
    end
end

function member_only_roots(stmt)
    roots = Symbol[]
    any_unquoted(node -> (Meta.isexpr(node, (:using, :import)) && append!(roots, import_roots(node)); false), stmt)
    filter!(root -> root ∉ (:Base, :Core, :Main) && Base.identify_package(String(root)) === nothing, unique!(roots))
end
