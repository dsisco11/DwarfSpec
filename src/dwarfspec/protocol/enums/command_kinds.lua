-- Closed command-category vocabulary for verified execution.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum dwarfspec.ECommandKind
return immutable_enum.define({
    QUERY='query',
    ASSERTION='assertion',
    ACTION='action',
    STATE_SETTER='state_setter',
    WORKFLOW='workflow',
    FIXTURE='fixture',
})

