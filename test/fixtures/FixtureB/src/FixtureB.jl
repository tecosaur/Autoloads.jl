module FixtureB

using FixtureA

export fa, fb

fb() = fa()

function __init__()
    get(ENV, "FIXTUREB_FAIL", "") == "1" && error("FixtureB refused to initialise: FIXTUREB_FAIL=1")
end

end
