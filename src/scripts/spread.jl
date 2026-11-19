# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Copying packages to, or removing them from, the autoloads members of other
# Julia versions, run by `Autoloads.add` and `remove` with `all_versions` as
#
#     julia spread.jl <add|remove> <source member> <names, comma-separated> <member>...
#
# `add` gives each member the source member's `[deps]`, `[compat]` and
# `[sources]` entries of the packages (a source its manifest records, before
# Pkg 1.13, counts); `remove` deletes theirs. Nothing is resolved: `spread!`
# defers a resolve to each member changed, for its own Julia version to apply
# when it next starts a session.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))

include("projectfiles.jl")

const SECTIONS = ("deps", "sources", "compat")

function main(op, source_dir, names, targets)
    source_file = joinpath(source_dir, "Project.toml")
    source = if op == "add" TOML.parsefile(source_file) else Dict{String, Any}() end
    recorded = if op == "add" manifest_sources(source_file) else Dict{String, Dict{String, Any}}() end
    deps = get(source, "deps", Dict{String, Any}())
    # Paths are made absolute, as the members are elsewhere.
    function wanted(section, name)
        entry = get(get(source, section, Dict{String, Any}()), name, nothing)
        if section == "sources" && entry === nothing && haskey(deps, name)
            entry = get(recorded, deps[name], nothing)
        end
        if entry isa AbstractDict && haskey(entry, "path")
            merge(entry, Dict("path" => normpath(joinpath(source_dir, entry["path"]))))
        else
            entry
        end
    end
    done, to = if op == "add"; ("Added ", " to ") else ("Removed ", " from ") end
    for member in targets
        project_file = joinpath(member, "Project.toml")
        project = TOML.parsefile(project_file)
        is_changed = false
        for section in SECTIONS, name in names
            table = get!(project, section, Dict{String, Any}())
            entry = wanted(section, name)
            get(table, name, nothing) == entry && continue
            is_changed = true
            if entry === nothing
                delete!(table, name)
            else
                table[name] = entry
            end
        end
        is_changed || continue
        filter!(((key, value),) -> !(key in SECTIONS && isempty(value)), project)
        write_toml(project_file, project)
        println(done, join(names, ", "), to, project_file)
    end
end

main(ARGS[1], ARGS[2], split(ARGS[3], ','), ARGS[4:end])
