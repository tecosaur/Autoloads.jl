# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module FixtureB

using FixtureA

export fa, fb

fb() = fa()

function __init__()
    get(ENV, "FIXTUREB_FAIL", "") == "1" && error("FixtureB refused to initialise: FIXTUREB_FAIL=1")
end

end
