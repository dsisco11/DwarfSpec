-- Immutable identifiers for supported DFHack state-change events.

local immutable_enum = require('dwarfspec.immutable_enum')

---@enum DwarfSpecEEvent
return immutable_enum.define({
    WORLD_LOADED='world_loaded',
    WORLD_UNLOADED='world_unloaded',
    MAP_LOADED='map_loaded',
    MAP_UNLOADED='map_unloaded',
    VIEWSCREEN_CHANGED='viewscreen_changed',
    PAUSED='paused',
    UNPAUSED='unpaused',
})
