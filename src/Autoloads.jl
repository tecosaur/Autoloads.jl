# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
    Autoloads

Load packages on demand in the REPL. Manage them with `pkg> autoloads` commands.
"""
module Autoloads

public init, add, remove, update, status, CatalogTooNew, ConfigError

include("records.jl")
include("catalogfile.jl")
include("config.jl")
include("envs.jl")
include("registry.jl")
include("manage.jl")
include("integration.jl")

end
