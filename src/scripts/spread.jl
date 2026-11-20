# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Run by `Autoloads.add` and `remove` with `allversions` as
#
#     julia spread.jl <add|remove> <source member> <names, comma-separated> <member>...
#
# Copies or deletes the packages' `[deps]`, `[compat]` and `[sources]` entries
# in the other members, without resolving.

const TOML = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))

include("projectfiles.jl")

const SECTIONS = ("deps", "sources", "compat")

function main(op, source_dir, names, targets)
    source = if op == "add" carrieddeps(joinpath(source_dir, "Project.toml")) else Dict{String, Any}() end
    done, to = if op == "add"; ("Added ", " to ") else ("Removed ", " from ") end
    for member in targets
        projectfile = joinpath(member, "Project.toml")
        project = TOML.parsefile(projectfile)
        ischanged = false
        for section in SECTIONS, name in names
            table = get!(project, section, Dict{String, Any}())
            entry = get(get(source, section, Dict{String, Any}()), name, nothing)
            get(table, name, nothing) == entry && continue
            ischanged = true
            if entry === nothing
                delete!(table, name)
            else
                table[name] = entry
            end
        end
        ischanged || continue
        filter!(((key, value),) -> !(key in SECTIONS && isempty(value)), project)
        writetoml(projectfile, project)
        println(done, join(names, ", "), to, projectfile)
    end
end

main(ARGS[1], ARGS[2], split(ARGS[3], ','), ARGS[4:end])
