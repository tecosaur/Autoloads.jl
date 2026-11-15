# Loading autoload packages into `Main`. A package the current environment
# provides is loaded from there. Otherwise the autoloads member is pushed onto
# `LOAD_PATH` for the duration of the load only, after checking that no
# already-loaded package conflicts with the member's manifest.

"""
    LoadState()

The loads tried this session: `attempted` holds `(id, name)` per
[`load!`](@ref) call (`name` is `nothing` for whole-package loads), `failed`
the packages that failed to load and are not retried.
"""
struct LoadState
    attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}
    failed::Set{Base.PkgId}
end

LoadState() = LoadState(Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(), Set{Base.PkgId}())

"""
    InconsistentVersions(id, conflicts)

Loading `id` from the autoloads member would mix versions: each conflict is
`(name, loaded version, member manifest version)`.
"""
struct InconsistentVersions <: Exception
    id::Base.PkgId
    conflicts::Vector{Tuple{String, VersionNumber, VersionNumber}}
end

function Base.showerror(io::IO, err::InconsistentVersions)
    differences = join(("$name v$loaded differs from v$wanted" for (name, loaded, wanted) in err.conflicts), ", ")
    print(io, "Not autoloading ", err.id.name, ": already-loaded ", differences,
          " in the autoloads environment. Add ", err.id.name, " to the active project to load it there.")
end

"""
    AutoloadFailure(id, reason, remedy)

Package `id` cannot be autoloaded because of `reason`; `remedy` says what to do.
"""
struct AutoloadFailure <: Exception
    id::Base.PkgId
    reason::String
    remedy::String
end

Base.showerror(io::IO, err::AutoloadFailure) =
    print(io, "Cannot autoload ", err.id.name, ": ", err.reason, ". ", err.remedy)

"""
    load!(state, req, member) -> Bool

Load `req.id` into `Main` (`using A.B`, or `using A.B: name` when `req.name`
is set), announcing it with an info line naming `req.trigger`. A package the
current `LOAD_PATH` provides (or a built-in) is loaded directly; otherwise
from the autoloads `member` directory, which is on `LOAD_PATH` only during
the load and only once every loaded package in its dependency closure matches
the member manifest's version. `LOAD_PATH` is unchanged afterwards.

Returns whether it loaded. A failure (including [`InconsistentVersions`](@ref)
and an [`AutoloadFailure`](@ref) for a package that is not installed) is
logged as one warning and recorded in `state.failed`; failed packages are
not retried. Every call records `(req.id, req.name)` in `state.attempted`,
except one interrupted by Ctrl-C: the `InterruptException` propagates and
nothing is recorded, so the load can be retried.
"""
function load!(state::LoadState, req::LoadRequest, member::AbstractString)
    key = (req.id, req.name)
    req.id in state.failed && return (push!(state.attempted, key); false)
    @info "Autoloading $(req.id.name) (for $(req.trigger))"
    loaded = try
        if is_in_current_env(req.id)
            Core.eval(Main, using_expr(req))
        else
            check_versions(req.id, member)
            with_member(member) do
                Base.locate_package(req.id) === nothing &&
                    throw(AutoloadFailure(req.id, "it is not installed in the autoloads environment",
                                          "Run `pkg> instantiate` with the global environment active to install it."))
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

"""
    eval_with_member(stmt, member)

Evaluate `stmt` in `Main`, with the autoloads `member` directory on
`LOAD_PATH` during evaluation if a package that a `using`/`import` in `stmt`
names cannot be found on the current `LOAD_PATH` (`Base`, `Core` and `Main`
never need it). Each such package that `member` provides first passes the
same version guard as [`load!`](@ref). `LOAD_PATH` is unchanged afterwards.

Raises [`InconsistentVersions`](@ref) when the guard fails, before anything
is evaluated; errors from `stmt` propagate.

# Example
```julia
eval_with_member(:(@time using DataFrames), Autoloads.member_dir())
```
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
    req.name === nothing ? Expr(:using, path) : Expr(:using, Expr(:(:), path, Expr(:., req.name)))
end

"Throw [`InconsistentVersions`](@ref) unless loaded packages `id` depends on match `member`'s manifest."
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
    isempty(conflicts) || throw(InconsistentVersions(id, sort!(conflicts)))
end

"Call `f()` with `member` appended to `LOAD_PATH`, removing exactly that entry afterwards."
function with_member(f, member::AbstractString)
    push!(LOAD_PATH, member)
    try
        f()
    finally
        index = findlast(==(member), LOAD_PATH)
        index === nothing || deleteat!(LOAD_PATH, index)
    end
end

"""
    member_only_roots(stmt) -> Vector{Symbol}

The package roots `stmt` imports (`A` of `using A.B`, `import A: x`,
`import A as B`) that the current `LOAD_PATH` cannot find; relative imports
and `Base`, `Core` and `Main` excluded.
"""
function member_only_roots(stmt)
    roots = Symbol[]
    function visit(ex)
        ex isa Expr || return
        if ex.head in (:using, :import)
            for arg in ex.args
                path = arg isa Expr && arg.head in (:(:), :as) ? first(arg.args) : arg
                path isa Expr && path.head === :. && first(path.args) !== :. && push!(roots, first(path.args))
            end
        else
            foreach(visit, ex.args)
        end
    end
    visit(stmt)
    filter!(root -> root ∉ (:Base, :Core, :Main) && Base.identify_package(String(root)) === nothing, roots)
end
