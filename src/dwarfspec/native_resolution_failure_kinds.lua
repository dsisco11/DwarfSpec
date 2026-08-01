-- Immutable failure kinds for native game-UI path resolution.

local immutable_enum = require('dwarfspec.support.immutable_enum')

---@enum DwarfSpecENativeResolutionFailureKind
return immutable_enum.define({
    INVALID_PATH='invalid_path',
    MAIN_INTERFACE_UNAVAILABLE='main_interface_unavailable',
    TYPE_UNAVAILABLE='type_unavailable',
    FIELD_METADATA_UNAVAILABLE='field_metadata_unavailable',
    INVALID_STRUCTURAL_SEGMENT='invalid_structural_segment',
    MISSING_FIELD='missing_field',
    NON_CONTAINER_VALUE='non_container_value',
    UNSUPPORTED_FIELD='unsupported_field',
    FIELD_ACCESS_FAILED='field_access_failed',
    UNSUPPORTED_FIELD_VALUE='unsupported_field_value',
    WIDGET_LOOKUP_FAILED='widget_lookup_failed',
    MISSING_WIDGET='missing_widget',
    FINAL_NOT_WIDGET='final_not_widget',
    IDENTITY_UNAVAILABLE='identity_unavailable',
})
