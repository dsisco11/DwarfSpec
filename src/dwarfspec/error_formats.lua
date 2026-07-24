-- Immutable identifiers for external CLI problem rendering formats.

local define = require('dwarfspec.immutable_enum').define

---@enum DwarfSpecErrorFormat
return define({
    MSBUILD='msbuild',
    GCC='gcc',
    ESLINT='eslint',
})
