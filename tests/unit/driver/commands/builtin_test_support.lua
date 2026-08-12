local Registrar = require(
    'dwarfspec.driver.command.builtin_command_registrar')
local TestRunner = dofile(
    'tests/unit/driver/commands/definition_test_support.lua')

---@class dwarfspec.tests.BuiltinCommandSupport
local Support = {}

---Registers owners against the lightweight definition test runner.
---@param owners table[]
---@return table, table, table
function Support.register(owners)
    local runner, ds, subject = TestRunner.new(), {}, {}
    Registrar.new({runner=runner, ds=ds, subject=subject})
        :register_all(owners)
    return runner, ds, subject
end

---Creates the complete scalar-game capability used by owner tests.
---@return table
function Support.game_runtime()
    return {is_game_paused=function() return false end,
        get_game_speed=function() return 100 end,
        get_tick=function() return 7 end,
        get_time=function() return 9 end,
        get_save_directory_name=function() return 'region1' end,
        has_focus=function(_, path) return path == 'dwarfmode' end}
end

---Creates the complete mount-query capability used by owner tests.
---@return table
function Support.mount_runtime()
    return {preflight=function() return true end,
        root=function() return 'root' end,
        get=function() return 'get' end,
        inspect=function() return 'inspect' end,
        capture_view_tree=function() return 'tree' end}
end

---Creates the complete subject-query capability used by owner tests.
---@return table
function Support.subject_runtime()
    return {raw=function(_, value) return value end,
        get_focus_list=function() return {'focus'} end}
end

return Support
