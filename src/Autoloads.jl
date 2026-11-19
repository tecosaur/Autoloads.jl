# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
Autoloads: load packages on demand at the REPL.

Management commands, also available as the `pkg> autoloads` command group:
[`init`](@ref) sets up the global autoloads environment; [`add`](@ref),
[`remove`](@ref) and [`update`](@ref) change its packages; [`status`](@ref)
reports what autoloads. They raise [`PkgOperationFailed`](@ref),
[`MemberMissing`](@ref), [`CatalogTooNew`](@ref) and, for invalid settings,
[`ConfigError`](@ref).
Everything else is internal.
"""
module Autoloads

public init, add, remove, update, status, PkgOperationFailed, MemberMissing, CatalogTooNew, ConfigError

include("records.jl")
include("catalogfile.jl")
include("config.jl")
include("envs.jl")
include("registry.jl")
include("manage.jl")
include("integration.jl")

end
