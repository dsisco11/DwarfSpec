-- Immutable state and ordered execution for composite command workflows.

local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local Immutable = require('dwarfspec.support.immutable')

---@class dwarfspec.WorkflowOutput
---@field name string
---@field has_value boolean
---@field value? any
local WorkflowOutput = {}
WorkflowOutput.__index = WorkflowOutput

---@class dwarfspec.WorkflowState
---@field request any
---@field outputs table<string, dwarfspec.WorkflowOutput>
local WorkflowState = {}
WorkflowState.__index = WorkflowState

---@class dwarfspec.CommandWorkflow
---@field private _definition dwarfspec.WorkflowDefinition
---@field private _request any
---@field private _outputs table<string, dwarfspec.WorkflowOutput>
---@field private _diagnostics dwarfspec.CommandDiagnostics
local Workflow = {}
Workflow.__index = Workflow

---Creates one immutable named workflow output.
---@param name string
---@param value any
---@return dwarfspec.WorkflowOutput
function WorkflowOutput.new(name, value)
    local output = {name=name, has_value=value ~= nil}
    if value ~= nil then output.value = value end
    return Immutable.freeze(output, 'workflow output')
end

---Creates an immutable workflow-state snapshot.
---@param request any
---@param outputs table<string, dwarfspec.WorkflowOutput>
---@return dwarfspec.WorkflowState
function WorkflowState.new(request, outputs)
    return Immutable.freeze({request=request, outputs=outputs},
        'workflow state', function(value)
            if value == request then return true end
            for _, output in pairs(outputs) do
                if value == output then return true end
            end
            return false
        end)
end

---Creates an ordered workflow over one normalized request.
---@param definition dwarfspec.WorkflowDefinition
---@param request any
---@return dwarfspec.CommandWorkflow
function Workflow.new(definition, request)
    assert(type(definition) == 'table', 'workflow definition is required')
    assert(type(definition.steps) == 'table', 'workflow steps are required')
    assert(type(definition.result) == 'function',
        'workflow result projector must be callable')
    local diagnostics = Diagnostics.new()
    return setmetatable({_definition=definition,
        _request=diagnostics:sanitize(request, 'workflow request'), _outputs={},
        _diagnostics=diagnostics}, Workflow)
end

---Returns the current immutable workflow state.
---@return dwarfspec.WorkflowState
function Workflow:state()
    return WorkflowState.new(self._request, self._outputs)
end

---Executes every step and commits only bounded successful outputs.
---@param execute_step fun(step: dwarfspec.WorkflowStepDefinition, state: dwarfspec.WorkflowState): any
---@return dwarfspec.WorkflowState
function Workflow:execute_steps(execute_step)
    assert(type(execute_step) == 'function',
        'workflow step executor must be callable')
    for _, step in ipairs(self._definition.steps) do
        local value = execute_step(step, self:state())
        local bounded
        if value ~= nil then
            bounded = self._diagnostics:sanitize(value,
                'workflow step output ' .. step.name)
        end
        self._outputs[step.name] = WorkflowOutput.new(step.name, bounded)
    end
    return self:state()
end

---Runs the pure result projector without permitting a cooperative yield.
---@param state dwarfspec.WorkflowState
---@return any
function Workflow:project(state)
    local projector = coroutine.create(function()
        return self._definition.result(state)
    end)
    local completed, projected = coroutine.resume(projector)
    if not completed then error(projected, 2) end
    assert(coroutine.status(projector) == 'dead',
        'workflow result projector must be synchronous and cannot yield')
    if projected ~= nil then
        projected = self._diagnostics:sanitize(projected,
            'workflow projected result')
    end
    return projected
end

---Executes every step and synchronously projects the stable result.
---@param execute_step fun(step: dwarfspec.WorkflowStepDefinition, state: dwarfspec.WorkflowState): any
---@return any, dwarfspec.WorkflowState
function Workflow:execute(execute_step)
    local state = self:execute_steps(execute_step)
    return self:project(state), state
end

return Workflow
