-- Structural validation contracts for immutable command definitions.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Definition = require('dwarfspec.driver.command.definition')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---Creates the smallest structurally valid non-workflow definition.
---@param kind string
---@param intrinsic string
---@param retry string
---@return table
local function executable(kind, intrinsic, retry)
    local value = {
        name=kind .. '_' .. intrinsic .. '_' .. retry,
        kind=kind,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready() end,
        execute=function() return Outcomes.executed() end,
        execution_retry_policy=retry,
        intrinsic_verification=intrinsic,
    }
    if intrinsic == IntrinsicKind.CALLBACK then
        value.verify = function() return Outcomes.ready() end
    end
    if retry == RetryPolicy.EXPLICIT_RETRY_SAFE then
        value.operation_key = function() return 'stable-operation' end
    end
    return value
end

---Creates the smallest structurally valid workflow definition.
---@return table
local function workflow()
    return {
        name='workflow', kind=CommandKind.WORKFLOW,
        normalize=function(arguments) return arguments end,
        preflight=function() return Outcomes.ready() end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
        workflow={
            steps={{
                name='observe', kind=CommandKind.QUERY,
                preflight=function() return Outcomes.ready() end,
                execute=function() return Outcomes.ready() end,
                execution_retry_policy=RetryPolicy.ONCE,
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION,
            }},
            result=function(state) return state end,
        },
    }
end

describe('command definition valid combinations', function()
    it('accepts every supported kind, intrinsic, and retry combination',
            function()
        for _, kind in ipairs({CommandKind.QUERY, CommandKind.ASSERTION}) do
            assert.is_table(Definition.validate(executable(kind,
                IntrinsicKind.PRIMARY_OBSERVATION, RetryPolicy.ONCE)))
        end
        for _, kind in ipairs({CommandKind.ACTION, CommandKind.STATE_SETTER,
                CommandKind.FIXTURE}) do
            for _, intrinsic in ipairs({IntrinsicKind.CALLBACK,
                    IntrinsicKind.EXECUTION_RECEIPT}) do
                for _, retry in ipairs({RetryPolicy.ONCE,
                        RetryPolicy.EXPLICIT_RETRY_SAFE}) do
                    assert.is_table(Definition.validate(
                        executable(kind, intrinsic, retry)))
                end
            end
        end
        assert.is_table(Definition.validate(workflow()))
    end)

    it('accepts coherent immutable cleanup and claim policy', function()
        local value = executable(CommandKind.FIXTURE,
            IntrinsicKind.CALLBACK, RetryPolicy.ONCE)
        value.claims = function() return {} end
        value.cleanup = {
            lifetime='owner',
            restore=function() end,
            verify=function() return true end,
            resources=function() return {} end,
        }
        local accepted = Definition.validate(value)
        assert.equals('owner', accepted.cleanup.lifetime)
        assert.has_error(function() accepted.cleanup.lifetime = 'command' end)
    end)
end)

describe('command definition invalid combinations', function()
    it('rejects malformed workflow and missing primary callbacks', function()
        local value = workflow()
        value.execute = function() end
        assert.has_error(function() Definition.validate(value) end)
        value = workflow()
        value.workflow.steps[1].preflight = nil
        assert.has_error(function() Definition.validate(value) end)
        value = workflow()
        value.workflow.steps[3] = value.workflow.steps[1]
        value.workflow.steps[1] = nil
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.preflight = nil
        assert.has_error(function() Definition.validate(value) end)
    end)

    it('rejects invalid verification and retry policies', function()
        local value = executable(CommandKind.ACTION,
            IntrinsicKind.CALLBACK, RetryPolicy.ONCE)
        value.verify = nil
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.verify = function() end
        assert.has_error(function() Definition.validate(value) end)
        value.operation_key = function() return 'not-used' end
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT,
            RetryPolicy.EXPLICIT_RETRY_SAFE)
        value.operation_key = nil
        assert.has_error(function() Definition.validate(value) end)
    end)

    it('rejects incoherent cleanup, claims, and timeout shapes', function()
        local value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.claims = function() return {} end
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.QUERY,
            IntrinsicKind.PRIMARY_OBSERVATION, RetryPolicy.ONCE)
        value.cleanup = {
            lifetime='owner', restore=function() end,
            verify=function() return true end,
        }
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.cleanup = {lifetime='owner', restore=function() end}
        assert.has_error(function() Definition.validate(value) end)
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.default_timeout_ms = false
        assert.has_error(function() Definition.validate(value) end)
    end)

    it('detaches and recursively freezes accepted definitions', function()
        local value = workflow()
        local accepted = Definition.validate(value)
        value.name = 'changed'
        value.workflow.steps[1].name = 'changed'
        assert.equals('workflow', accepted.name)
        assert.equals('observe', accepted.workflow.steps[1].name)
        assert.has_error(function() accepted.name = 'changed' end)
        assert.has_error(function()
            accepted.workflow.steps[1].name = 'changed'
        end)
    end)
end)
