# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module FixtureA

export fa, @fam, FA_CONST
public fa_public

const FA_CONST = 1

fa() = :fa
fa_public() = :fa_public

macro fam(ex)
    esc(ex)
end

end
