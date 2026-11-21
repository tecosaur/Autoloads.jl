# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module FixtureC

export fc

fc() = :fc

# FIXTUREC_CRASH exits the process; FIXTUREC_EXIT_CRASH fails its exit;
# FIXTUREC_HANG never returns; FIXTUREC_INTERRUPT acts as a Ctrl-C during loading;
# FIXTUREC_SPAWN starts a lasting process sharing its stdio, writing its pid there.
function __init__()
    haskey(ENV, "FIXTUREC_SPAWN") &&
        write(ENV["FIXTUREC_SPAWN"], string(getpid(run(pipeline(`sleep 60`; stdout); wait = false))))
    get(ENV, "FIXTUREC_CRASH", "") == "1" && exit(3)
    get(ENV, "FIXTUREC_EXIT_CRASH", "") == "1" && atexit(() -> exit(3))
    get(ENV, "FIXTUREC_HANG", "") == "1" && sleep(3600)
    get(ENV, "FIXTUREC_INTERRUPT", "") == "1" && throw(InterruptException())
end

end
