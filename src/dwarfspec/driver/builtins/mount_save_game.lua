-- Verified workflow definition for exact save-game mounting.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local Workflow = require('dwarfspec.driver.game.save_game_mount')
local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.MountSaveGameCommandDefinition
---@field private _runtime dwarfspec.SaveGameRuntime
local MountSaveGameDefinition = {}
MountSaveGameDefinition.__index = MountSaveGameDefinition

---Creates the mountSaveGame workflow command owner.
---@param runtime dwarfspec.SaveGameRuntime
---@return dwarfspec.MountSaveGameCommandDefinition
function MountSaveGameDefinition.new(runtime)
    assert(type(runtime) == 'table',
        'mount-save-game command runtime is required')
    for _, name in ipairs({'host', 'is_world_loaded', 'unload',
            'reach_save_menu', 'select_save_world',
            'select_save_and_await_map', 'verify_loaded'}) do
        assert(type(runtime[name]) == 'function',
            'mount-save-game command runtime requires ' .. name)
    end
    return setmetatable({_runtime=runtime}, MountSaveGameDefinition)
end

---Normalizes the requested save directory.
---@param arguments table
---@return table
function MountSaveGameDefinition:_normalize(arguments)
    return {directory_name=Workflow.validate_directory_name(
        1, arguments.directory_name)}
end

---Inspects the current and requested save state.
---@param request table
---@return table
function MountSaveGameDefinition:_inspect(request)
    return Workflow.preflight(self._runtime:host(), 1,
        request.directory_name)
end

---Unloads a different currently loaded save when required.
---@param state table
---@return string|nil
function MountSaveGameDefinition:_unload_current(state)
    local current = self:_inspect(state.request)
    if current.loaded_directory and current.transition_required then
        self._runtime:unload(current.loaded_directory,
            current.requested_directory)
    end
    return current.loaded_directory
end

---Reaches the save menu unless the requested world is already loaded.
---@param state table
---@return table
function MountSaveGameDefinition:_reach_menu(state)
    if self._runtime:is_world_loaded() then
        return {already_loaded=true}
    end
    return self._runtime:reach_save_menu(
        state.request.directory_name)
end

---Selects the requested world from the save menu.
---@param state table
---@return table
function MountSaveGameDefinition:_select_world(state)
    local menu = state.outputs.reach_save_menu.value
    if menu.already_loaded then return menu end
    return self._runtime:select_save_world(
        state.request.directory_name, menu.world_id)
end

---Selects the exact save and awaits its map transition.
---@param state table
---@return string
function MountSaveGameDefinition:_select_save(state)
    if not self._runtime:is_world_loaded() then
        local selection = state.outputs.select_save_world.value
        self._runtime:select_save_and_await_map(
            state.request.directory_name, selection.save_index)
    end
    return state.request.directory_name
end

---Confirms that a map is loaded after save selection.
---@param state table
---@return string
function MountSaveGameDefinition:_await_map(state)
    assert(self._runtime:is_world_loaded(),
        'DwarfSpec mountSaveGame did not observe a loaded map')
    return state.request.directory_name
end

---Verifies the exact requested save directory is loaded.
---@param state table
---@return string
function MountSaveGameDefinition:_verify_loaded(state)
    return self._runtime:verify_loaded(state.request.directory_name)
end

---Creates one named, exactly-once workflow action.
---@param name string
---@param execute function
---@return table
function MountSaveGameDefinition:_step(name, execute)
    return {name=name, kind=CommandKind.ACTION,
        preflight=function() return Outcomes.ready(true) end,
        execute=function(context, state)
            local value = execute(context, state)
            return Outcomes.executed(value, {step=name})
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
end

---Creates the immutable workflow definition.
---@return table
function MountSaveGameDefinition:definition()
    return Definition.validate({name='mountSaveGame', kind=CommandKind.WORKFLOW,
        normalize=function(arguments) return self:_normalize(arguments) end,
        preflight=function(context, request)
            return Outcomes.ready(self:_inspect(request))
        end,
        workflow={steps={
            self:_step('unload_current_save', function(_, state)
                return self:_unload_current(state)
            end),
            self:_step('reach_save_menu', function(_, state)
                return self:_reach_menu(state)
            end),
            self:_step('select_save_world', function(_, state)
                return self:_select_world(state)
            end),
            self:_step('select_save_game', function(_, state)
                return self:_select_save(state)
            end),
            self:_step('await_save_map', function(_, state)
                return self:_await_map(state)
            end),
            self:_step('verify_loaded_save', function(_, state)
                return self:_verify_loaded(state)
            end),
        }, result=function(state)
            local output = state.outputs.verify_loaded_save
            return output.has_value and output.value or
                state.request.directory_name
        end},
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
end

---Adapts the public mountSaveGame signature for the runner.
---@param directory_name string
---@param command_options? table
---@return table, table|nil
function MountSaveGameDefinition:arguments(directory_name, command_options)
    return {directory_name=directory_name}, command_options
end

return MountSaveGameDefinition
