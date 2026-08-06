-- Closed intrinsic-verification vocabulary for command definitions.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.EIntrinsicVerificationKind
return immutable_enum.define({
    PRIMARY_OBSERVATION='primary_observation',
    CALLBACK='callback',
    EXECUTION_RECEIPT='execution_receipt',
})

