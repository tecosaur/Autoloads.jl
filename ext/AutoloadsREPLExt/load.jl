# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Loading into `Main`: from the active environment when it has the package, else
# with the member briefly on `LOAD_PATH`, after a version check.

struct LoadState
    attempted::Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}
    failed::Set{Base.PkgId}
end

LoadState() = LoadState(Set{Tuple{Base.PkgId, Union{Symbol, Nothing}}}(), Set{Base.PkgId}())

"""
    load!(state::LoadState, req::LoadRequest, member::AbstractString; announce::Bool = true) -> Bool

Load `req` into `Main`: from the active environment if it has the package, else
from `member`, once the versions it would load agree with those loaded or
earlier on `LOAD_PATH`. Returns
whether it loaded; a failure is logged once, and not retried until
`forgetfailures!`. An interrupt propagates and records nothing.
"""
function load!(state::LoadState, req::LoadRequest, member::AbstractString; announce::Bool = true)
    key = (req.id, req.name)
    req.id in state.failed && return (push!(state.attempted, key); false)
    announce && @info "Autoloading $(req.id.name) (for $(req.trigger))"
    path = Expr(:., Symbol.(split(req.id.name, '.'))...)
    usingstmt = Expr(:using, if req.name === nothing path else Expr(:(:), path, Expr(:., req.name)) end)
    loaded = try
        if req.id.uuid === nothing || Base.identify_package(req.id.name) == req.id
            Core.eval(Main, usingstmt)
        else
            checkversions(req.id, member)
            withmember(member) do
                Base.locate_package(req.id) === nothing &&
                    error("$(req.id.name) is not installed in the autoloads environment; ",
                          "run `pkg> instantiate` with the global environment active to install it")
                Core.eval(Main, usingstmt)
            end
        end
        true
    catch err
        isinterrupt(err) && throw(InterruptException())
        @warn "Failed to autoload $(req.id.name)" exception = (err, catch_backtrace())
        push!(state.failed, req.id)
        false
    end
    push!(state.attempted, key)
    loaded
end

function forgetfailures!(state::LoadState)
    isempty(state.failed) && return
    filter!(((id, _),) -> id ∉ state.failed, state.attempted)
    empty!(state.failed)
    nothing
end

"""
    evalwithmember(stmt, member::AbstractString)

Evaluate `stmt` in `Main`, with `member` on `LOAD_PATH` while it does if `stmt`
imports a package only `member` provides, after `load!`'s version check.
"""
function evalwithmember(stmt, member::AbstractString)
    roots = Symbol[]
    anyunquoted(node -> (Meta.isexpr(node, (:using, :import)) && append!(roots, importroots(node)); false), stmt)
    filter!(root -> root ∉ (:Base, :Core, :Main) && Base.identify_package(String(root)) === nothing, unique!(roots))
    isempty(roots) && return Core.eval(Main, stmt)
    memberids = projectdeps(joinpath(member, "Project.toml"))
    for root in roots
        index = findfirst(id -> id.name == String(root), memberids)
        index === nothing || checkversions(memberids[index], member)
    end
    withmember(() -> Core.eval(Main, stmt), member)
end

# Utility functions

# A Ctrl-C during a package's `__init__` or top level arrives wrapped.
isinterrupt(err) = err isa InterruptException ||
    (err isa Union{Base.InitError, LoadError} && isinterrupt(err.error))

function checkversions(id::Base.PkgId, member::AbstractString)
    graph = manifestgraph(joinpath(member, "Project.toml"))
    closure = dependencyclosure(graph, id.uuid)
    # What would load: the loaded version, else the first on `LOAD_PATH`, where the member comes last.
    loading = Dict{Base.UUID, Tuple{Union{VersionNumber, Nothing}, String}}()
    for env in reverse(Base.load_path()), (uuid, version) in manifestgraph(env).versions
        loading[uuid] = (version, "from $(Base.contractuser(env))")
    end
    @lock Base.require_lock for (pkg, mod) in Base.loaded_modules
        pkg.uuid in closure && (loading[pkg.uuid] = (pkgversion(mod), "already loaded"))
    end
    conflicts = String[]
    for uuid in closure
        wanted = @something(get(graph.versions, uuid, nothing), continue)
        actual, source = @something(get(loading, uuid, nothing), continue)
        actual === nothing || actual == wanted ||
            push!(conflicts, "$(graph.names[uuid]) v$actual ($source) differs from v$wanted")
    end
    isempty(conflicts) && return
    error("Cannot load $(id.name) from the autoloads environment: $(join(sort!(conflicts), ", ")) there. ",
          "Add $(id.name) to the active project to load it there.")
end

function withmember(f, member::AbstractString)
    push!(LOAD_PATH, member)
    try
        f()
    finally
        index = findlast(==(member), LOAD_PATH)
        index === nothing || deleteat!(LOAD_PATH, index)
    end
end
