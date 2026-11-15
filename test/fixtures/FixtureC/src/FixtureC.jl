module FixtureC

export fc

fc() = :fc

# FIXTUREC_CRASH exits the process; FIXTUREC_HANG never returns.
function __init__()
    get(ENV, "FIXTUREC_CRASH", "") == "1" && exit(3)
    get(ENV, "FIXTUREC_HANG", "") == "1" && sleep(3600)
end

end
