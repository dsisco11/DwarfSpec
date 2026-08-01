-- Immutable stages for native subject resolution diagnostics.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecENativeResolutionStage
return immutable_enum.define({
    STRUCTURE_TRAVERSAL='structure_traversal',
    WIDGET_TRAVERSAL='widget_traversal',
    AMBIGUITY_CHECK='ambiguity_check',
    RETAINED_SUBJECT_REACQUISITION='retained_subject_reacquisition',
})
