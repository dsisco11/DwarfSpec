-- Structural validation contracts for immutable command definitions.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Definition = require('dwarfspec.driver.command.definition')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')

---Returns complete qualification documentation for a synthetic retry policy.
---@return table
local function retry_safety()
    return {stable_operation_key='normalized request identity',
        idempotency_guarantee='same key cannot duplicate the logical effect',
        attempt_receipt_policy='every attempted effect returns a receipt',
        effect_receipt_policy='every reversible effect returns cleanup identity',
        conformance_fixture='command definition synthetic retry fixture'}
end

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
        value.retry_safety = retry_safety()
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
    it('qualifies a stable bounded operation key from one normalized request',
            function()
        local value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT,
            RetryPolicy.EXPLICIT_RETRY_SAFE)
        value.normalize = function(arguments)
            return {subject=tostring(arguments.subject)}
        end
        value.operation_key = function(request)
            return 'synthetic:' .. request.subject
        end
        local definition = Definition.validate(value)
        local request = definition.normalize({subject=7})
        local first = definition.operation_key(request)
        local second = definition.operation_key(request)
        assert.equals('synthetic:7', first)
        assert.equals(first, second)
        assert.is_true(#first <= 128)
    end)

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
        for _, kind in ipairs({CommandKind.QUERY, CommandKind.ASSERTION,
                CommandKind.ACTION, CommandKind.STATE_SETTER,
                CommandKind.FIXTURE}) do
            local intrinsic = (kind == CommandKind.QUERY or
                kind == CommandKind.ASSERTION) and
                IntrinsicKind.PRIMARY_OBSERVATION or
                IntrinsicKind.EXECUTION_RECEIPT
            local step = executable(kind, intrinsic, RetryPolicy.ONCE)
            step.name = 'step-' .. kind
            step.normalize = nil
            step.default_timeout_ms = nil
            local value = workflow()
            value.workflow.steps = {step}
            assert.is_table(Definition.validate(value))
        end
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
        value = workflow()
        value.workflow.steps[2] = value.workflow.steps[1]
        assert.has_error(function() Definition.validate(value) end)
        value = workflow()
        value.workflow.steps[1].kind = CommandKind.WORKFLOW
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
        for _, missing in ipairs({'stable_operation_key',
                'idempotency_guarantee', 'attempt_receipt_policy',
                'effect_receipt_policy', 'conformance_fixture'}) do
            value = executable(CommandKind.ACTION,
                IntrinsicKind.EXECUTION_RECEIPT,
                RetryPolicy.EXPLICIT_RETRY_SAFE)
            value.retry_safety[missing] = nil
            assert.has_error(function() Definition.validate(value) end)
        end
        value = executable(CommandKind.ACTION,
            IntrinsicKind.EXECUTION_RECEIPT, RetryPolicy.ONCE)
        value.retry_safety = retry_safety()
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
        local result = value.workflow.result
        local accepted = Definition.validate(value)
        value.name = 'changed'
        value.workflow.steps[1].name = 'changed'
        assert.equals('workflow', accepted.name)
        assert.equals('observe', accepted.workflow.steps[1].name)
        assert.is_true(accepted.workflow.result == result)
        assert.has_error(function() accepted.name = 'changed' end)
        assert.has_error(function()
            accepted.workflow.steps[1].name = 'changed'
        end)
    end)

    it('rejects cyclic definition tables with command attribution', function()
        local value = workflow()
        value.workflow.loop = value.workflow
        local succeeded, message = pcall(Definition.validate, value)
        assert.is_false(succeeded)
        assert.is_truthy(tostring(message):find(
            'command definition', 1, true))
        assert.is_truthy(tostring(message):find('acyclic', 1, true))
    end)
end)
