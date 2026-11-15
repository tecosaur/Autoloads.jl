# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module FixtureC

export fc

fc() = :fc

# FIXTUREC_CRASH exits the process; FIXTUREC_HANG never returns;
# FIXTUREC_INTERRUPT acts as a Ctrl-C during loading.
function __init__()
    get(ENV, "FIXTUREC_CRASH", "") == "1" && exit(3)
    get(ENV, "FIXTUREC_HANG", "") == "1" && sleep(3600)
    get(ENV, "FIXTUREC_INTERRUPT", "") == "1" && throw(InterruptException())
end

end
