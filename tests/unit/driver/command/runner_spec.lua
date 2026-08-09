-- Deterministic lifecycle tests for the common verified command runner.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Registry = require('dwarfspec.driver.command.registry')
local Runner = require('dwarfspec.driver.command.runner')
local CleanupRegistrationService = require(
    'dwarfspec.driver.cleanup.cleanup_registration_service')
local CleanupLifetime = require('dwarfspec.protocol.enums.cleanup_lifetimes')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---Returns complete qualification documentation for a synthetic retry policy.
---@return table
local function retry_safety()
    return {stable_operation_key='normalized request identity',
        idempotency_guarantee='same key cannot duplicate the logical effect',
        attempt_receipt_policy='every attempted effect returns a receipt',
        effect_receipt_policy='every reversible effect returns cleanup identity',
        conformance_fixture='common command runner synthetic retry fixture'}
end

---Asserts that one invocation reports a stage and bounded evidence fragment.
---@param callback fun()
---@param stage string
---@param evidence_fragment string
---@return string
local function assert_stage_failure(callback, stage, evidence_fragment)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    message = tostring(message)
    assert.is_truthy(message:find(stage .. ':', 1, true), message)
    assert.is_truthy(message:find('latest evidence: ' .. evidence_fragment,
        1, true), message)
    return message
end

---Asserts one complete start/finish event pair and its terminal outcome.
---@param events table[]
---@param status string
---@param stage? string
local function assert_terminal_events(events, status, stage)
    assert.equals(2, #events)
    assert.same({'command.started', 'command.finished'}, {
        events[1].event_type, events[2].event_type})
    assert.equals(status, events[2].payload.status)
    if stage ~= nil then assert.equals(stage, events[2].payload.stage) end
end

---Creates complete inert context dependencies around a controlled fake clock.
---@return table, table
local function dependencies()
    local state = {now=0, checkpoints=0}
    local result = {
        now_ms=function() return state.now end,
        wait=function() state.now = state.now + 1 end,
        cancellation=function() return false, nil end,
        owner=function()
            return {owner_scope='test_attempt', service_run_id='run',
                suite_execution_id='suite', test_attempt_id='attempt'}
        end,
        cleanup_checkpoint=function()
            state.checkpoints = state.checkpoints + 1
            return state.checkpoints
        end,
        new_cancellation=function() return function() return false end end,
        invoke_readonly=function() end,
        record_diagnostic=function() end,
        assert_cleanup_executable=function() end,
        resolve_mount=function() end,
        resolve_target=function() end,
        lookup_claim=function() end,
        capture_render=function() end,
        observe_render=function() end,
        wait_frames=function() end,
        wait_ticks=function() end,
        wait_event=function() end,
        wait_until=function() end,
        execute_step=function() end,
        remaining_ms=function() return 1 end,
    }
    return result, state
end

---Creates one runner with no-op ownership services for no-effect commands.
---@param registry dwarfspec.CommandRegistry
---@param injected table
---@return dwarfspec.CommandRunner
local function runner(registry, injected, cleanup_service, resource_index)
    return Runner.new({registry=registry, default_timeout_ms=10,
        dependencies=injected, resource_index=resource_index or {
            validate_plan=function() return {} end},
        cleanup_service=cleanup_service or {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function() end}})
end

---Invokes one command while proving no timed lifecycle dependency is touched.
---@param registry dwarfspec.CommandRegistry
---@param name string
---@param expected_failure string
---@return string
local function assert_normalization_failure(registry, name, expected_failure)
    local injected = dependencies()
    local calls = {clock=0, owner=0, checkpoint=0, publish=0}
    injected.now_ms=function()
        calls.clock = calls.clock + 1
        return 0
    end
    injected.owner=function()
        calls.owner = calls.owner + 1
        error('owner must not be resolved')
    end
    injected.cleanup_checkpoint=function()
        calls.checkpoint = calls.checkpoint + 1
        error('checkpoint must not be marked')
    end
    injected.publish=function()
        calls.publish = calls.publish + 1
        error('event must not be published')
    end
    local message = assert_stage_failure(function()
        runner(registry, injected):invoke(name, {})
    end, 'normalization', '<none>')
    assert.is_truthy(message:find(expected_failure, 1, true), message)
    assert.same({clock=0, owner=0, checkpoint=0, publish=0}, calls)
    return message
end

describe('common command runner', function()
    it('attributes a thrown normalizer before the timed lifecycle', function()
        local registry, preflights = Registry.new(), 0
        registry:register_builtin({name='normalizer-failure',
            kind=CommandKind.QUERY,
            normalize=function() error('normalizer failed') end,
            preflight=function()
                preflights = preflights + 1
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        assert_normalization_failure(registry, 'normalizer-failure',
            'normalizer failed')
        assert.equals(0, preflights)
    end)

    it('attributes normalized-request sanitizer rejection', function()
        local registry = Registry.new()
        registry:register_builtin({name='normalization-sanitizer-failure',
            kind=CommandKind.QUERY,
            normalize=function() return {callback=function() end} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        assert_normalization_failure(registry,
            'normalization-sanitizer-failure', 'normalized command request')
    end)

    it('attributes thrown and invalid retry-safe operation keys', function()
        for _, fixture in ipairs({
            {name='operation-key-failure', operation_key=function()
                error('operation key failed')
            end, expected='operation key failed'},
            {name='invalid-operation-key', operation_key=function() return '' end,
                expected='command operation key must be a bounded nonempty string'},
        }) do
            local registry = Registry.new()
            registry:register_builtin({name=fixture.name, kind=CommandKind.ACTION,
                normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.executed(true, {receipt=true}) end,
                execution_retry_policy='explicit_retry_safe',
                operation_key=fixture.operation_key,
                retry_safety=retry_safety(),
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            assert_normalization_failure(registry, fixture.name, fixture.expected)
        end
    end)

    it('normalizes synchronously and returns an execution receipt result unchanged',
            function()
        local registry = Registry.new()
        registry:register_builtin({name='set', kind=CommandKind.ACTION,
            normalize=function(arguments) return {value=arguments.value} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function(_, request)
                return require('dwarfspec.driver.command.outcomes')
                    .executed(request.value, {acknowledged=true})
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        assert.equals('value', runner(registry, injected):invoke('set',
            {value='value'}))
        assert.equals(2, state.checkpoints)
    end)

    it('uses one deadline while retrying read-only preflight observations',
            function()
        local registry, polls = Registry.new(), 0
        registry:register_builtin({name='query', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function()
                polls = polls + 1
                if polls == 1 then return require('dwarfspec.driver.command.outcomes')
                    .pending('not ready') end
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(nil) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected, state = dependencies()
        assert.is_nil(runner(registry, injected):invoke('query', {}))
        assert.equals(3, polls)
        assert.equals(1, state.now)
    end)

    it('finalizes command-lifetime cleanup after intrinsic success', function()
        local registry, cleanup_calls, lease_active = Registry.new(), 0, false
        registry:register_builtin({name='temporary', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {confirmed=true}, {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local cleanup_service = {begin_mutation=function()
            assert.is_false(lease_active)
            lease_active = true
            return {release=function()
                assert.is_true(lease_active)
                lease_active = false
            end}
        end, register=function()
            assert.is_true(lease_active)
            return {isPending=function() return true end,
                execute=function()
                    cleanup_calls = cleanup_calls + 1
                    return true
                end}
        end}
        assert.equals('done', runner(registry, injected, cleanup_service)
            :invoke('temporary', {}))
        assert.equals(1, cleanup_calls)
        assert.is_false(lease_active)
    end)

    it('preserves pending primary observations separately from a nil result',
            function()
        local registry, observations = Registry.new(), 0
        registry:register_builtin({name='find', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready({target_identity='target-1'}) end,
            execute=function()
                observations = observations + 1
                if observations == 1 then
                    return require('dwarfspec.driver.command.outcomes')
                        .pending('render has not settled')
                end
                return require('dwarfspec.driver.command.outcomes').ready(nil)
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected, state = dependencies()
        assert.is_nil(runner(registry, injected):invoke('find', {}))
        assert.equals(2, observations)
        assert.equals(1, state.now)
    end)

    it('rejects an explicit retry result from a once-only mutation', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='once', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function()
                executions = executions + 1
                return require('dwarfspec.driver.command.outcomes')
                    .retry('retry is not permitted')
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        assert.has_error(function()
            runner(registry, injected):invoke('once', {})
        end)
        assert.equals(1, executions)
    end)

    it('runs caller verification after intrinsic success without replacing the result',
            function()
        local registry, verifications = Registry.new(), 0
        registry:register_builtin({name='verified', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready({target_identity='target-1'}) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('public result', {receipt='private'}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        assert.equals('public result', runner(registry, injected):invoke(
            'verified', {}, {verify=function(observation)
                verifications = verifications + 1
                assert.equals('verified', observation.name)
                assert.equals('public result', observation.public_result)
                assert.equals('target-1', observation.stable_target_identity)
                if verifications == 1 then error('assertion is not ready') end
                return true
            end}))
        assert.equals(2, verifications)
        assert.equals(1, state.now)
    end)

    it('derives the retry-safe operation key before claim-plan validation',
            function()
        local registry, received_key = Registry.new(), nil
        registry:register_builtin({name='retryable', kind=CommandKind.ACTION,
            normalize=function() return {subject='stable'} end,
            operation_key=function(request) return 'key:' .. request.subject end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .retry('not completed') end,
            execution_retry_policy='explicit_retry_safe',
            retry_safety=retry_safety(),
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local index = {validate_plan=function(_, _, _, _, _, key)
            received_key = key
            return {}
        end}
        assert.has_error(function()
            runner(registry, injected, nil, index):invoke('retryable', {})
        end)
        assert.equals('key:stable', received_key)
    end)

    it('runs command-lifetime cleanup when intrinsic verification fails',
            function()
        local registry, cleanup_calls = Registry.new(), 0
        registry:register_builtin({name='unconfirmed', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('private', {receipt='value'}, {resource='temporary'}) end,
            verify=function() return require('dwarfspec.driver.command.outcomes')
                .fatal('effect was not confirmed') end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local injected = dependencies()
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        assert.has_error(function()
            runner(registry, injected, cleanup_service):invoke('unconfirmed', {})
        end)
        assert.equals(1, cleanup_calls)
    end)

    it('publishes one start and terminal event around a completed lifecycle',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='evented', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {receipt='value'}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        injected.publish=function(event_type, payload)
            if event_type == 'command.started' then
                assert.equals(0, state.checkpoints)
            end
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.equals('done', runner(registry, injected):invoke('evented',
            {option='value'}))
        assert_terminal_events(events, 'success', 'completed')
        assert.equals(2, state.checkpoints)
    end)

    it('publishes one failed terminal event after an execution failure',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='broken', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() error('adapter failed') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.has_error(function() runner(registry, injected):invoke('broken', {}) end)
        assert_terminal_events(events, 'failure', 'execution')
    end)

    it('attributes a thrown start-event publisher before command callbacks',
            function()
        local registry, preflights, publications = Registry.new(), 0, 0
        registry:register_builtin({name='start-publication-failure',
            kind=CommandKind.QUERY, normalize=function() return {} end,
            preflight=function()
                preflights = preflights + 1
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected, state = dependencies()
        injected.publish=function()
            publications = publications + 1
            assert.equals(0, state.checkpoints)
            error('start publisher failed')
        end
        assert_stage_failure(function()
            runner(registry, injected):invoke('start-publication-failure', {})
        end, 'result_projection', '<none>')
        assert.equals(1, publications)
        assert.equals(0, preflights)
        assert.equals(0, state.checkpoints)
    end)

    it('finalizes a command-checkpoint failure after start publication',
            function()
        local registry, events, preflights, cleanups = Registry.new(), {}, 0, 0
        registry:register_builtin({name='checkpoint-failure',
            kind=CommandKind.QUERY, normalize=function() return {} end,
            preflight=function()
                preflights = preflights + 1
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.cleanup_checkpoint=function()
            error('checkpoint failed')
        end
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function() end,
            pendingCommandTransactions=function()
                return {}
            end}
        local message = assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('checkpoint-failure', {})
        end, 'preflight', '<none>')
        assert.is_truthy(message:find('checkpoint failed', 1, true))
        assert.equals(0, preflights)
        assert.equals(0, cleanups)
        assert_terminal_events(events, 'failure', 'preflight')
    end)

    it('attributes a malformed cleanup discovery result before terminal output',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='malformed-cleanup-discovery',
            kind=CommandKind.QUERY, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.ready('done') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function() end,
            pendingCommandTransactions=function() return nil end}
        local message = assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('malformed-cleanup-discovery', {})
        end, 'command_cleanup_discovery', '{kind="primary_observation"}')
        assert.is_truthy(message:find(
            'command cleanup discovery must return a table', 1, true))
        assert_terminal_events(events, 'failure', 'command_cleanup_discovery')
    end)

    it('attributes throwing pending-state inspection during finalization',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='pending-inspection-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                return Outcomes.executed('done', {receipt=true}, {effect=true})
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            cleanup={lifetime=CleanupLifetime.COMMAND,
                restore=function() end, verify=function() return true end}})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() error('pending inspection failed') end,
                execute=function() error('cleanup must not execute') end}
        end}
        local message = assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('pending-inspection-failure', {})
        end, 'command_cleanup', '{receipt=true}')
        assert.is_truthy(message:find('pending inspection failed', 1, true))
        assert_terminal_events(events, 'failure', 'command_cleanup')
    end)

    it('appends pending-state failure after an earlier execution failure',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='composed-pending-inspection-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                return Outcomes.failed('primary failed', {effect=true},
                    {marker='execution'})
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            cleanup={lifetime=CleanupLifetime.COMMAND,
                restore=function() end, verify=function() return true end}})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() error('pending inspection failed') end,
                execute=function() error('cleanup must not execute') end}
        end}
        local succeeded, message = pcall(function()
            runner(registry, injected, cleanup_service)
                :invoke('composed-pending-inspection-failure', {})
        end)
        assert.is_false(succeeded)
        message = tostring(message)
        local primary_at = assert(message:find('execution:', 1, true))
        local cleanup_at = assert(message:find('command_cleanup:', 1, true))
        assert.is_true(primary_at < cleanup_at)
        assert.is_truthy(message:find('primary failed', 1, true))
        assert.is_truthy(message:find('pending inspection failed', 1, true))
        assert.is_truthy(message:find(
            'latest evidence: {marker="execution"}', 1, true))
        assert_terminal_events(events, 'failure', 'execution')
    end)

    it('attributes terminal publication failure after lifecycle success',
            function()
        local registry, executions, terminal_attempts = Registry.new(), 0, 0
        registry:register_builtin({name='terminal-publication-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                executions = executions + 1
                return Outcomes.executed('public', {marker='intrinsic'})
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type)
            if event_type == 'command.finished' then
                terminal_attempts = terminal_attempts + 1
                error('terminal publisher failed')
            end
        end
        assert_stage_failure(function()
            runner(registry, injected):invoke('terminal-publication-failure', {})
        end, 'result_projection', '{marker="intrinsic"}')
        assert.equals(1, executions)
        assert.equals(1, terminal_attempts)
    end)

    it('appends terminal publication failure after an earlier command failure',
            function()
        local registry, terminal_attempts = Registry.new(), 0
        registry:register_builtin({name='composed-publication-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                return Outcomes.failed('primary failed', nil,
                    {marker='execution'})
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type)
            if event_type == 'command.finished' then
                terminal_attempts = terminal_attempts + 1
                error('terminal publisher failed')
            end
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('composed-publication-failure', {})
        end)
        assert.is_false(succeeded)
        message = tostring(message)
        local primary_at = assert(message:find('execution:', 1, true))
        local publication_at = assert(message:find('result_projection:', 1, true))
        assert.is_true(primary_at < publication_at)
        assert.is_truthy(message:find('primary failed', 1, true))
        assert.is_truthy(message:find('terminal publisher failed', 1, true))
        assert.is_truthy(message:find(
            'latest evidence: {marker="execution"}', 1, true))
        assert.equals(1, terminal_attempts)
    end)

    it('expires preflight without executing primary behavior', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='blocked', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .pending('target is not ready') end,
            execute=function() executions = executions + 1 end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('blocked', {}, {timeout_ms=2})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('last pending: target is not ready',
            1, true))
        assert.equals(0, executions)
    end)

    it('honors cancellation before preflight callbacks', function()
        local registry, preflights = Registry.new(), 0
        registry:register_builtin({name='cancelled', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function()
                preflights = preflights + 1
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end, execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.cancellation=function() return true, 'cancel requested' end
        assert.has_error(function()
            runner(registry, injected):invoke('cancelled', {})
        end)
        assert.equals(0, preflights)
    end)

    it('rejects unsupported trailing invocation options before normalization',
            function()
        local registry, normalizations = Registry.new(), 0
        registry:register_builtin({name='options', kind=CommandKind.QUERY,
            normalize=function()
                normalizations = normalizations + 1
                return {}
            end, preflight=function()
                return require('dwarfspec.driver.command.outcomes').ready(true)
            end, execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        assert.has_error(function()
            runner(registry, dependencies()):invoke('options', {}, {unknown=true})
        end)
        assert.equals(0, normalizations)
    end)

    it('abandons a registered self-rolled-back effect through the real cleanup service',
            function()
        local registry, command_events, cleanup_events = Registry.new(), {}, {}
        registry:register_builtin({name='rolled-back', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('private', {receipt='value'}, {item_id='item-1'}) end,
            verify=function() return require('dwarfspec.driver.command.outcomes')
                .effect_absent('effect self-rolled back', {
                    absent_resources={{resource_kind='item',
                        resource_identity='item-1'}}}) end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            cleanup={lifetime='command', resources=function()
                return {{claim_key='item'}}
            end, restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            command_events[#command_events + 1] = {event_type=event_type,
                payload=payload}
        end
        local resource_index = ResourceDependencyIndex.new('run', function()
            return 'abandoned'
        end)
        local cleanup_service = CleanupRegistrationService.new({service_run_id='run',
            resource_index=resource_index, now_ms=injected.now_ms,
            publish_event=function(event) cleanup_events[#cleanup_events + 1] = event end})
        local succeeded, message = pcall(function()
            runner(registry, injected, cleanup_service, resource_index)
                :invoke('rolled-back', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('intrinsic_verification:', 1, true), message)
        assert.is_truthy(message:find('effect self-rolled back', 1, true))
        assert.same({'cleanup.transaction_registered',
            'cleanup.transaction_abandoned'}, {cleanup_events[1].event_type,
                cleanup_events[2].event_type})
        assert.equals(2, #cleanup_events)
        assert.same({}, cleanup_service:pendingCommandTransactions('run:command:1'))
        local lease = cleanup_service:begin_mutation('next-command')
        lease:release()
        resource_index:validate_plan(injected.owner(), 'next-command',
            CleanupLifetime.COMMAND, {{claim_key='item', resource_kind='item',
                resource_identity='item-1', exclusive=true}})
        assert_terminal_events(command_events, 'failure',
            'intrinsic_verification')
    end)

    it('composes primary and command-lifetime cleanup failures', function()
        local registry = Registry.new()
        registry:register_builtin({name='partial', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .failed('primary failed', {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() error('cleanup failed') end}
        end}
        local succeeded, message = pcall(function()
            runner(registry, dependencies(), cleanup_service):invoke('partial', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('primary failed', 1, true))
        assert.is_truthy(message:find('command_cleanup:', 1, true))
        assert.is_truthy(message:find('cleanup failed', 1, true))
    end)

    it('does not drain owner-lifetime cleanup at command completion', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='retained', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('done', {receipt='value'}, {resource='retained'}) end,
            cleanup={lifetime='owner', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() executions = executions + 1 end}
        end}
        assert.equals('done', runner(registry, dependencies(), cleanup_service)
            :invoke('retained', {}))
        assert.equals(0, executions)
    end)

    it('rejects forged runtime gates with exact preflight attribution', function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='forged-gate', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return {kind='ready', value=true} end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('forged-gate', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('outcome constructor', 1, true))
        assert.equals('preflight', events[2].payload.stage)
    end)

    it('requires an immutable execution receipt for receipt verification',
            function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='missing-receipt', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value') end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('missing-receipt', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('immutable receipt', 1, true))
        assert.equals('execution', events[2].payload.stage)
    end)

    it('runs command cleanup from finally after unexpected intrinsic failure',
            function()
        local registry, cleanup_calls = Registry.new(), 0
        registry:register_builtin({name='finally-cleanup', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}, {resource='temporary'}) end,
            verify=function() return {kind='ready', value=true} end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        local succeeded, message = pcall(function()
            runner(registry, dependencies(), cleanup_service)
                :invoke('finally-cleanup', {})
        end)
        assert.is_false(succeeded)
        assert.equals(1, cleanup_calls)
        assert.is_truthy(message:find('intrinsic_verification:', 1, true))
    end)

    it('quarantines a thrown mutating adapter with an ambiguous effect', function()
        local registry, quarantine = Registry.new(), nil
        registry:register_builtin({name='ambiguous', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() error('adapter disconnected') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function(_, invocation_id, owner, evidence)
            quarantine = {invocation_id=invocation_id, owner=owner,
                evidence=evidence}
        end}
        assert.has_error(function()
            runner(registry, dependencies(), cleanup_service):invoke('ambiguous', {})
        end)
        assert.is_not_nil(quarantine)
        assert.equals('execution', quarantine.evidence.stage)
        assert.is_truthy(quarantine.evidence.failure:find(
            'adapter disconnected', 1, true))
    end)

    it('quarantines a malformed mutating adapter result', function()
        local registry, quarantine = Registry.new(), nil
        registry:register_builtin({name='malformed', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return {kind='executed', public_result='forged'} end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function(_, _, _, evidence)
            quarantine = evidence
        end}
        assert.has_error(function()
            runner(registry, dependencies(), cleanup_service)
                :invoke('malformed', {})
        end)
        assert.equals('execution', quarantine.stage)
        assert.is_truthy(quarantine.failure:find('outcome constructor', 1, true))
    end)

    it('refreshes retained subjects after cleanup and before terminal success',
            function()
        local registry, calls = Registry.new(), {}
        registry:register_builtin({name='refresh', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}, {resource='temporary'}) end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end}, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type)
            if event_type == 'command.finished' then calls[#calls + 1] = 'finish' end
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() calls[#calls + 1] = 'cleanup' end}
        end}
        local command_runner = runner(registry, injected, cleanup_service)
        command_runner:setRefreshRetainedSubjects(function()
            calls[#calls + 1] = 'refresh'
        end)
        assert.equals('value', command_runner:invoke('refresh', {}))
        assert.same({'cleanup', 'refresh', 'finish'}, calls)
    end)

    it('attributes retained-subject refresh failure before terminal publication',
            function()
        local registry, terminal = Registry.new(), nil
        registry:register_builtin({name='refresh-failure', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return require('dwarfspec.driver.command.outcomes')
                .ready(true) end,
            execute=function() return require('dwarfspec.driver.command.outcomes')
                .executed('value', {receipt=true}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            if event_type == 'command.finished' then terminal = payload end
        end
        local command_runner = runner(registry, injected)
        command_runner:setRefreshRetainedSubjects(function()
            error('refresh failed')
        end)
        local succeeded, message = pcall(function()
            command_runner:invoke('refresh-failure', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(message:find('retained_subject_refresh:', 1, true))
        assert.is_truthy(message:find('latest evidence: {receipt=true}', 1, true))
        assert.equals('failure', terminal.status)
        assert.equals('retained_subject_refresh', terminal.stage)
    end)

    it('retains bounded evidence through lifecycle and finalization failures',
            function()
        ---Registers one definition in a fresh isolated command registry.
        ---@param definition dwarfspec.CommandDefinition
        ---@return dwarfspec.CommandRegistry
        local function register(definition)
            local registry = Registry.new()
            registry:register_builtin(definition)
            return registry
        end

        ---Invokes one isolated registry while retaining only the dependency table.
        ---@param registry dwarfspec.CommandRegistry
        ---@param name string
        ---@param options? table
        ---@param cleanup_service? table
        ---@return any
        local function invoke(registry, name, options, cleanup_service)
            local injected = dependencies()
            return runner(registry, injected, cleanup_service):invoke(name, {},
                options)
        end

        assert_stage_failure(function()
            local registry = register({name='preflight-evidence',
                kind=CommandKind.QUERY, normalize=function() return {} end,
                preflight=function()
                    return Outcomes.fatal('preflight failed', {marker='preflight'})
                end, execute=function() return Outcomes.ready(true) end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
            invoke(registry, 'preflight-evidence')
        end, 'preflight', '{marker="preflight"}')

        assert_stage_failure(function()
            local registry = register({name='execution-evidence',
                kind=CommandKind.ACTION, normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function()
                    return Outcomes.failed('execution failed', nil,
                        {marker='execution'})
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            invoke(registry, 'execution-evidence')
        end, 'execution', '{marker="execution"}')

        assert_stage_failure(function()
            local registry = register({name='intrinsic-evidence',
                kind=CommandKind.ACTION, normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.executed('done', {receipt=true}) end,
                verify=function()
                    return Outcomes.fatal('intrinsic failed', {marker='intrinsic'})
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.CALLBACK})
            invoke(registry, 'intrinsic-evidence')
        end, 'intrinsic_verification', '{marker="intrinsic"}')

        assert_stage_failure(function()
            local registry = register({name='caller-evidence', kind=CommandKind.QUERY,
                normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.ready('done') end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
            invoke(registry, 'caller-evidence', {
                verify=function() error('caller observation failed') end})
        end, 'caller_verification', '{message=')

        assert_stage_failure(function()
            local registry = register({name='lease-evidence', kind=CommandKind.ACTION,
                normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.executed('done', {receipt=true}) end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            local cleanup_service = {begin_mutation=function()
                return {release=function() error('lease release failed') end}
            end}
            invoke(registry, 'lease-evidence', nil, cleanup_service)
        end, 'mutation_lease_release', '{receipt=true}')

        assert_stage_failure(function()
            local registry = register({name='cleanup-evidence', kind=CommandKind.ACTION,
                normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function()
                    return Outcomes.executed('done', {receipt=true}, {item_id='item-1'})
                end, cleanup={lifetime='command', restore=function() end,
                    verify=function() return true end}, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            local cleanup_service = {begin_mutation=function()
                return {release=function() end}
            end, register=function()
                return {isPending=function() return true end,
                    execute=function() error('cleanup execution failed') end}
            end}
            invoke(registry, 'cleanup-evidence', nil, cleanup_service)
        end, 'command_cleanup', '{receipt=true}')

        assert_stage_failure(function()
            local registry = register({name='cleanup-discovery-evidence',
                kind=CommandKind.ACTION, normalize=function() return {} end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.executed('done', {receipt=true}) end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            local cleanup_service = {begin_mutation=function()
                return {release=function() end}
            end, pendingCommandTransactions=function()
                error('cleanup discovery failed')
            end}
            invoke(registry, 'cleanup-discovery-evidence', nil, cleanup_service)
        end, 'command_cleanup_discovery', '{receipt=true}')
    end)

    it('attributes claim-planning failure before primary execution', function()
        local registry, events, executions = Registry.new(), {}, 0
        registry:register_builtin({name='claim-failure', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function()
                return Outcomes.ready(true, {marker='claim-ready'})
            end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            execute=function()
                executions = executions + 1
                return Outcomes.executed('unexpected', {receipt=true})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local resource_index = {validate_plan=function()
            error('claim plan rejected')
        end}
        assert_stage_failure(function()
            runner(registry, injected, nil, resource_index)
                :invoke('claim-failure', {})
        end, 'claim_planning', '{marker="claim-ready"}')
        assert.equals(0, executions)
        assert_terminal_events(events, 'failure', 'claim_planning')
    end)

    it('keeps final ready evidence after pending preflight observations', function()
        local registry, polls = Registry.new(), 0
        registry:register_builtin({name='claim-ready-evidence',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function()
                polls = polls + 1
                if polls == 1 then
                    return Outcomes.pending('not ready', {marker='pending'})
                end
                return Outcomes.ready(true, {marker='ready'})
            end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            execute=function()
                return Outcomes.executed('unexpected', {receipt=true})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local resource_index = {validate_plan=function()
            error('claim plan rejected')
        end}
        assert_stage_failure(function()
            runner(registry, dependencies(), nil, resource_index)
                :invoke('claim-ready-evidence', {})
        end, 'claim_planning', '{marker="ready"}')
    end)

    it('keeps preflight evidence when execution supplies none', function()
        local registry, injected = Registry.new(), dependencies()
        registry:register_builtin({name='execution-without-evidence',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function()
                return Outcomes.ready(true, {marker='preflight'})
            end,
            execute=function()
                return Outcomes.failed('execution failed')
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        assert_stage_failure(function()
            runner(registry, injected):invoke(
                'execution-without-evidence', {})
        end, 'execution', '{marker="preflight"}')
    end)

    it('keeps preflight evidence when read-only execution supplies none',
            function()
        local registry, injected = Registry.new(), dependencies()
        registry:register_builtin({name='observation-without-evidence',
            kind=CommandKind.QUERY, normalize=function() return {} end,
            preflight=function()
                return Outcomes.ready(true, {marker='preflight'})
            end,
            execute=function()
                return Outcomes.fatal('observation failed')
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        assert_stage_failure(function()
            runner(registry, injected):invoke(
                'observation-without-evidence', {})
        end, 'execution', '{marker="preflight"}')
    end)

    it('keeps earlier evidence when intrinsic success supplies none', function()
        local registry, injected = Registry.new(), dependencies()
        registry:register_builtin({name='intrinsic-without-evidence',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function()
                return Outcomes.ready(true, {marker='preflight'})
            end,
            execute=function()
                return Outcomes.executed('public', {receipt=true})
            end,
            verify=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local command_runner = runner(registry, injected)
        command_runner:setRefreshRetainedSubjects(function()
            error('refresh failed')
        end)
        assert_stage_failure(function()
            command_runner:invoke('intrinsic-without-evidence', {})
        end, 'retained_subject_refresh', '{marker="preflight"}')
    end)

    it('keeps intrinsic evidence through caller success and refresh failure',
            function()
        local registry, injected = Registry.new(), dependencies()
        registry:register_builtin({name='caller-without-evidence',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                return Outcomes.executed('public', {marker='intrinsic'})
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local command_runner = runner(registry, injected)
        command_runner:setRefreshRetainedSubjects(function()
            error('refresh failed')
        end)
        assert_stage_failure(function()
            command_runner:invoke('caller-without-evidence', {}, {
                verify=function() return true end})
        end, 'retained_subject_refresh', '{marker="intrinsic"}')
    end)

    it('attributes cleanup-registration failure and releases its lease', function()
        local registry, events, executions, releases = Registry.new(), {}, 0, 0
        registry:register_builtin({name='registration-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                executions = executions + 1
                return Outcomes.failed('effect failed', {item_id='item-1'},
                    {marker='registration'})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() releases = releases + 1 end}
        end, register=function() error('cleanup registration failed') end}
        assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('registration-failure', {})
        end, 'cleanup_registration', '{marker="registration"}')
        assert.equals(1, executions)
        assert.equals(1, releases)
        assert_terminal_events(events, 'failure', 'cleanup_registration')
    end)

    it('cleans a registered effect after synchronous execution overruns', function()
        local registry, events = Registry.new(), {}
        local executions, cleanup_calls = 0, 0
        registry:register_builtin({name='execution-overrun',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                executions = executions + 1
                return Outcomes.executed('late', {receipt=true},
                    {item_id='item-1'})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            state.now = 2
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('execution-overrun', {}, {timeout_ms=2})
        end, 'execution', '<none>')
        assert.equals(1, executions)
        assert.equals(1, cleanup_calls)
        assert_terminal_events(events, 'failure', 'execution')
    end)

    it('times out intrinsic verification then expends command cleanup', function()
        local registry, events = Registry.new(), {}
        local executions, cleanup_calls = 0, 0
        registry:register_builtin({name='intrinsic-timeout',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                executions = executions + 1
                return Outcomes.executed('private', {receipt=true},
                    {item_id='item-1'})
            end,
            verify=function()
                return Outcomes.pending('intrinsic pending',
                    {marker='intrinsic-pending'})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        assert_stage_failure(function()
            runner(registry, injected, cleanup_service)
                :invoke('intrinsic-timeout', {}, {timeout_ms=2})
        end, 'intrinsic_verification',
            '{evidence={marker="intrinsic-pending"}, message="intrinsic pending"}')
        assert.equals(1, executions)
        assert.equals(1, cleanup_calls)
        assert_terminal_events(events, 'failure', 'intrinsic_verification')
    end)

    it('times out caller verification then expends command cleanup', function()
        local registry, events = Registry.new(), {}
        local executions, cleanup_calls = 0, 0
        registry:register_builtin({name='caller-timeout', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                executions = executions + 1
                return Outcomes.executed('public', {receipt=true},
                    {item_id='item-1'})
            end,
            cleanup={lifetime='command', restore=function() end,
                verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local cleanup_service = {begin_mutation=function()
            return {release=function() end}
        end, register=function()
            return {isPending=function() return true end,
                execute=function() cleanup_calls = cleanup_calls + 1 end}
        end}
        assert_stage_failure(function()
            runner(registry, injected, cleanup_service):invoke('caller-timeout',
                {}, {timeout_ms=2, verify=function() return false end})
        end, 'caller_verification',
            '{message="caller verification is not yet satisfied"}')
        assert.equals(1, executions)
        assert.equals(1, cleanup_calls)
        assert_terminal_events(events, 'failure', 'caller_verification')
    end)

    it('revalidates and yields until an explicit retry reaches success', function()
        local registry, executions, preflights, claims = Registry.new(), 0, 0, 0
        local operation_keys, diagnostics, events = {}, {}, {}
        registry:register_builtin({name='retry-eventual', kind=CommandKind.ACTION,
            normalize=function(arguments) return {subject=arguments.subject} end,
            operation_key=function(request)
                operation_keys[#operation_keys + 1] = 'key:' .. request.subject
                return operation_keys[#operation_keys]
            end,
            retry_safety=retry_safety(),
            preflight=function(context)
                preflights = preflights + 1
                assert.equals(executions + 1, context:identity().attempt)
                return Outcomes.ready({target_identity='target-' ..
                    tostring(executions + 1)})
            end,
            claims=function()
                claims = claims + 1
                return {}
            end,
            execute=function()
                executions = executions + 1
                if executions < 3 then
                    return Outcomes.retry('native operation pending',
                        {attempt=executions}, nil, {marker='retry-' .. executions})
                end
                return Outcomes.executed('done', {attempt=executions})
            end,
            cleanup={lifetime=CleanupLifetime.COMMAND,
                restore=function() end, verify=function() return true end},
            execution_retry_policy='explicit_retry_safe',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected, state = dependencies()
        injected.record_diagnostic=function(kind, evidence)
            diagnostics[#diagnostics + 1] = {kind=kind, evidence=evidence}
        end
        injected.publish=function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.equals('done', runner(registry, injected):invoke(
            'retry-eventual', {subject='stable'}, {verify=function(observation)
                assert.equals(2, #observation.attempt_receipts)
                assert.equals(1,
                    observation.attempt_receipts[1].receipt.attempt)
                assert.equals(2,
                    observation.attempt_receipts[2].receipt.attempt)
                return true
            end}))
        assert.equals(3, executions)
        assert.equals(6, preflights)
        assert.equals(3, claims)
        assert.equals(2, state.now)
        assert.same({'key:stable'}, operation_keys)
        assert.equals(2, #diagnostics)
        assert.equals('command.retry', diagnostics[1].kind)
        assert.is_true(diagnostics[1].evidence.attempt_receipt_present)
        assert.equals(3, events[2].payload.attempt_count)
        assert.equals('key:stable', events[2].payload.operation_key)
        assert.equals(2, #events[2].payload.retry_attempts)
        assert.has_error(function()
            events[2].payload.retry_attempts[1].attempt = 99
        end)
    end)

    it('cleans a forced command-lifetime retry effect before re-execution',
            function()
        local registry, executions, restores, cleanup_events =
            Registry.new(), 0, 0, {}
        registry:register_builtin({name='retry-effect', kind=CommandKind.FIXTURE,
            normalize=function() return {} end,
            operation_key=function() return 'retry-effect:stable' end,
            retry_safety=retry_safety(),
            preflight=function() return Outcomes.ready(true) end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            execute=function()
                executions = executions + 1
                if executions == 1 then
                    return Outcomes.retry('created transient item',
                        {native_attempt=1}, {item_id='item-1'})
                end
                assert.equals(1, restores)
                return Outcomes.executed('done', {native_attempt=2})
            end,
            cleanup={lifetime=CleanupLifetime.OWNER,
                resources=function(receipt)
                    return {{claim_key='item',
                        resource_identity=receipt.item_id}}
                end,
                restore=function(_, receipt)
                    assert.equals('item-1', receipt.item_id)
                    restores = restores + 1
                end,
                verify=function() return true end},
            execution_retry_policy='explicit_retry_safe',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local resource_index = ResourceDependencyIndex.new('run', function()
            return 'complete'
        end)
        local cleanup_service = CleanupRegistrationService.new({
            service_run_id='run', resource_index=resource_index,
            now_ms=injected.now_ms, publish_event=function(event)
                cleanup_events[#cleanup_events + 1] = event
            end})
        assert.equals('done', runner(registry, injected, cleanup_service,
            resource_index):invoke('retry-effect', {}))
        assert.equals(2, executions)
        assert.equals(1, restores)
        assert.same({'cleanup.transaction_registered',
            'cleanup.transaction_started', 'cleanup.transaction_finished'},
            {cleanup_events[1].event_type, cleanup_events[2].event_type,
                cleanup_events[3].event_type})
        assert.equals(CleanupLifetime.COMMAND,
            cleanup_events[1].lifetime)
        assert.same({}, cleanup_service:pendingCommandTransactions(
            'run:command:1'))
    end)

    it('terminates retry when prior-attempt cleanup is not confirmed', function()
        local registry, executions = Registry.new(), 0
        registry:register_builtin({name='retry-cleanup-failure',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            operation_key=function() return 'cleanup-failure:stable' end,
            retry_safety=retry_safety(),
            preflight=function() return Outcomes.ready(true) end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            execute=function()
                executions = executions + 1
                return Outcomes.retry('partial effect', {attempt=executions},
                    {item_id='item-1'})
            end,
            cleanup={lifetime=CleanupLifetime.OWNER,
                resources=function(receipt)
                    return {{claim_key='item',
                        resource_identity=receipt.item_id}}
                end,
                restore=function() error('restore failed') end,
                verify=function() return false end},
            execution_retry_policy='explicit_retry_safe',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        local resource_index = ResourceDependencyIndex.new('run', function()
            return 'complete'
        end)
        local cleanup_service = CleanupRegistrationService.new({
            service_run_id='run', resource_index=resource_index,
            now_ms=injected.now_ms})
        local message = assert_stage_failure(function()
            runner(registry, injected, cleanup_service, resource_index)
                :invoke('retry-cleanup-failure', {}, {timeout_ms=3})
        end, 'retry_cleanup', '{attempt=1')
        assert.is_truthy(message:find('cleanup transaction failed', 1, true),
            message)
        assert.equals(1, executions)
    end)

    it('shares cancellation and the absolute deadline across attempts', function()
        for _, fixture in ipairs({
            {name='cancelled', timeout_ms=5, cancellation=function(executions)
                return executions > 0, 'cancel requested'
            end, expected='cancelled: cancel requested'},
            {name='timed-out', timeout_ms=1, cancellation=function()
                return false
            end, expected='command deadline expired'},
        }) do
            local registry, executions = Registry.new(), 0
            registry:register_builtin({name='retry-' .. fixture.name,
                kind=CommandKind.ACTION, normalize=function() return {} end,
                operation_key=function() return fixture.name .. ':stable' end,
                retry_safety=retry_safety(),
                preflight=function() return Outcomes.ready(true) end,
                execute=function()
                    executions = executions + 1
                    return Outcomes.retry('explicit retry',
                        {attempt=executions})
                end,
                execution_retry_policy='explicit_retry_safe',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            local injected = dependencies()
            injected.cancellation=function()
                return fixture.cancellation(executions)
            end
            local succeeded, message = pcall(function()
                runner(registry, injected):invoke('retry-' .. fixture.name,
                    {}, {timeout_ms=fixture.timeout_ms})
            end)
            assert.is_false(succeeded)
            assert.is_truthy(tostring(message):find(fixture.expected, 1, true),
                tostring(message))
            assert.equals(1, executions)
        end
    end)

    it('never infers retry from fatal, thrown, nil, or false execution', function()
        for _, fixture in ipairs({
            {name='fatal', execute=function()
                return Outcomes.failed('fatal execution')
            end},
            {name='throw', execute=function() error('thrown execution') end},
            {name='nil', execute=function() return nil end},
            {name='false', execute=function() return false end},
        }) do
            local registry, executions = Registry.new(), 0
            registry:register_builtin({name='retry-' .. fixture.name,
                kind=CommandKind.ACTION, normalize=function() return {} end,
                operation_key=function() return fixture.name .. ':stable' end,
                retry_safety=retry_safety(),
                preflight=function() return Outcomes.ready(true) end,
                execute=function(...)
                    executions = executions + 1
                    return fixture.execute(...)
                end,
                execution_retry_policy='explicit_retry_safe',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
            local injected = dependencies()
            local succeeded, message = pcall(function()
                runner(registry, injected):invoke('retry-' ..
                    fixture.name, {})
            end)
            assert.is_false(succeeded)
            assert.equals(1, executions, fixture.name .. ': ' .. tostring(message))
        end
    end)

    it('executes workflow steps under one inherited command tree', function()
        local registry, events, identities = Registry.new(), {}, {}
        local injected = dependencies()
        injected.resolve_target = function(identity)
            assert.equals('unit-7', identity)
            return {stable_identity=identity}
        end
        injected.publish = function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        registry:register_builtin({name='composite', kind=CommandKind.WORKFLOW,
            normalize=function(arguments) return {unit_id=arguments.unit_id} end,
            preflight=function(context)
                identities.outer = context:identity()
                return Outcomes.ready(true)
            end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            workflow={steps={{name='observe', kind=CommandKind.QUERY,
                preflight=function(context, state)
                    identities.observe = context:identity()
                    assert.equals('unit-7', state.request.unit_id)
                    return Outcomes.ready(true)
                end,
                execute=function(_, state)
                    return Outcomes.ready({unit_id=state.request.unit_id})
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION},
            {name='mutate', kind=CommandKind.ACTION,
                preflight=function(context, state)
                    identities.mutate = context:identity()
                    local target = context:resolve_target(
                        state.outputs.observe.value.unit_id)
                    return Outcomes.ready(target)
                end,
                execute=function(_, state, ready)
                    assert.equals('unit-7', ready.stable_identity)
                    assert.equals('unit-7',
                        state.outputs.observe.value.unit_id)
                    return Outcomes.executed({changed=true}, {confirmed=true})
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT},
            {name='empty', kind=CommandKind.ACTION,
                preflight=function() return Outcomes.ready(true) end,
                execute=function()
                    return Outcomes.executed(nil, {confirmed=true})
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}},
            result=function(state)
                assert.is_false(state.outputs.empty.has_value)
                return {changed=state.outputs.mutate.value.changed}
            end}})
        local result = runner(registry, injected):invoke('composite',
            {unit_id='unit-7'})
        assert.is_true(result.changed)
        assert.equals(8, #events)
        assert.equals(identities.outer.invocation_id,
            identities.observe.parent_invocation_id)
        assert.equals(identities.outer.invocation_id,
            identities.mutate.parent_invocation_id)
        assert.equals(identities.outer.root_invocation_id,
            identities.mutate.root_invocation_id)
        assert.equals(identities.outer.owner_scope,
            identities.mutate.owner_scope)
        assert.not_equals(identities.observe.invocation_id,
            identities.mutate.invocation_id)
        for _, event in ipairs(events) do
            assert.equals(identities.outer.root_invocation_id,
                event.payload.command.root_invocation_id)
            assert.equals(identities.outer.owner_scope,
                event.payload.command.owner_scope)
        end
    end)

    it('attributes workflow result projection to primary execution', function()
        local registry, events = Registry.new(), {}
        registry:register_builtin({name='projection-failure',
            kind=CommandKind.WORKFLOW, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            workflow={steps={{name='observe', kind=CommandKind.QUERY,
                preflight=function() return Outcomes.ready(true) end,
                execute=function() return Outcomes.ready(true) end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}},
                result=function() error('projection failed') end}})
        local injected = dependencies()
        injected.publish = function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local message = assert_stage_failure(function()
            runner(registry, injected):invoke('projection-failure', {})
        end, 'execution', '<none>')
        assert.is_truthy(message:find('projection failed', 1, true), message)
        assert.equals('failure', events[#events].payload.status)
        assert.equals('execution', events[#events].payload.stage)
    end)

    it('inherits boundaries for nested public reads and rejects mutation', function()
        local registry, events, child_identities, leaf_identities =
            Registry.new(), {}, {}, {}
        registry:register_builtin({name='nested-leaf', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function(context)
                leaf_identities[#leaf_identities + 1] = context:identity()
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready('leaf') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        registry:register_builtin({name='nested-query', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function(context)
                child_identities[#child_identities + 1] = context:identity()
                assert.equals(10, context:remaining_ms())
                assert.equals('leaf', context:invoke_readonly(
                    CommandKind.QUERY, 'nested-leaf', {}))
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready('nested') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        registry:register_builtin({name='nested-action', kind=CommandKind.ACTION,
            normalize=function(arguments) return arguments end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.executed(true, {done=true}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local parent_identity
        registry:register_builtin({name='read-parent', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function(context)
                parent_identity = context:identity()
                assert.equals('nested', context:invoke_readonly(
                    CommandKind.QUERY, 'nested-query', {}))
                assert.has_error(function()
                    context:invoke_readonly(CommandKind.ACTION,
                        'nested-action', {})
                end)
                assert.has_error(function()
                    context:invoke_readonly(CommandKind.QUERY,
                        'nested-query', {}, {timeout_ms=20})
                end)
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready('parent') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.publish = function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        assert.equals('parent', runner(registry, injected):invoke(
            'read-parent', {}))
        assert.equals(4, #child_identities)
        for _, child in ipairs(child_identities) do
            assert.equals(parent_identity.invocation_id,
                child.parent_invocation_id)
            assert.equals(parent_identity.root_invocation_id,
                child.root_invocation_id)
            assert.equals(parent_identity.test_attempt_id,
                child.test_attempt_id)
        end
        assert.equals(child_identities[1].invocation_id,
            child_identities[2].invocation_id)
        assert.not_equals(child_identities[1].invocation_id,
            child_identities[3].invocation_id)
        assert.equals(8, #leaf_identities)
        for _, leaf in ipairs(leaf_identities) do
            assert.equals(parent_identity.root_invocation_id,
                leaf.root_invocation_id)
            assert.is_truthy(leaf.parent_invocation_id)
        end
        assert.equals(14, #events)
        for _, event in ipairs(events) do
            assert.equals(parent_identity.root_invocation_id,
                event.payload.command.root_invocation_id)
            assert.equals(parent_identity.owner_scope,
                event.payload.command.owner_scope)
        end
    end)

    it('shares cancellation with nested public reads', function()
        local registry, cancellation_checks = Registry.new(), 0
        registry:register_builtin({name='cancel-child', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        registry:register_builtin({name='cancel-parent', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function(context)
                context:invoke_readonly(CommandKind.QUERY, 'cancel-child', {})
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        local injected = dependencies()
        injected.cancellation = function()
            cancellation_checks = cancellation_checks + 1
            return cancellation_checks >= 3, 'shared cancellation'
        end
        local succeeded, message = pcall(function()
            runner(registry, injected):invoke('cancel-parent', {})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(tostring(message):find(
            'cancelled: shared cancellation', 1, true), tostring(message))
        assert.equals(3, cancellation_checks)
    end)

    it('roots cleanup verification reads at their cleanup transaction', function()
        local registry, cleanup_child, events = Registry.new(), nil, {}
        registry:register_builtin({name='cleanup-query', kind=CommandKind.QUERY,
            normalize=function(arguments) return arguments end,
            preflight=function(context)
                cleanup_child = context:identity()
                return Outcomes.ready(true)
            end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
        registry:register_builtin({name='cleanup-parent', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            claims=function()
                return {{claim_key='item', resource_kind='item',
                    resource_identity='item-1', exclusive=true}}
            end,
            execute=function()
                return Outcomes.executed(true, {done=true}, {item_id='item-1'})
            end,
            cleanup={lifetime=CleanupLifetime.COMMAND,
                resources=function(receipt)
                    return {{claim_key='item',
                        resource_identity=receipt.item_id}}
                end,
                restore=function() end,
                verify=function(context)
                    return context:invoke_readonly(CommandKind.QUERY,
                        'cleanup-query', {})
                end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT})
        local injected = dependencies()
        injected.owner = function()
            return {owner_scope='service_run', service_run_id='run'}
        end
        injected.publish = function(event_type, payload)
            events[#events + 1] = {event_type=event_type, payload=payload}
        end
        local index = ResourceDependencyIndex.new('run', function()
            return 'complete'
        end)
        local cleanup = CleanupRegistrationService.new({service_run_id='run',
            resource_index=index, now_ms=injected.now_ms})
        assert.is_true(runner(registry, injected, cleanup, index):invoke(
            'cleanup-parent', {}))
        assert.is_truthy(cleanup_child.parent_cleanup_transaction_id)
        assert.is_nil(cleanup_child.parent_invocation_id)
        assert.equals(cleanup_child.invocation_id,
            cleanup_child.root_invocation_id)
        assert.equals('service_run', cleanup_child.owner_scope)
        assert.is_nil(cleanup_child.suite_execution_id)
        assert.is_nil(cleanup_child.test_attempt_id)
        local cleanup_child_events = 0
        for _, event in ipairs(events) do
            if event.payload.command.parent_cleanup_transaction_id ~= nil then
                cleanup_child_events = cleanup_child_events + 1
                assert.equals(cleanup_child.invocation_id,
                    event.payload.command.root_invocation_id)
                assert.equals('service_run',
                    event.payload.command.owner_scope)
            end
        end
        assert.equals(2, cleanup_child_events)
    end)
end)
