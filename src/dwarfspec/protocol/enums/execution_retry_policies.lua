-- Closed primary-execution retry vocabulary.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.EExecutionRetryPolicy
return immutable_enum.define({
    ONCE='once',
    EXPLICIT_RETRY_SAFE='explicit_retry_safe',
})

