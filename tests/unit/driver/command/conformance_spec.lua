-- Table-driven reusable qualification for the common command engine.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Harness = dofile('tests/unit/driver/command/engine_harness.lua')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')

---Returns a complete reusable fixture declaration.
---@param definition table
---@param expected string[]
---@return table
local function fixture(definition, expected)
    return {definition=definition, gate='ready', execution='completed',
        intrinsic=definition.intrinsic_verification, timeout='finite',
        retry_safety=definition.execution_retry_policy,
        cleanup=definition.cleanup and 'declared' or 'none',
        expected_observations=expected}
end

---Returns the ordered stage/status observations from a harness run.
---@param events table[]
---@return string[]
local function observations(events)
    local result = {}
    for _, event in ipairs(events) do
        if event.kind == 'command.stage' then
            result[#result + 1] = event.payload.stage .. ':' ..
                event.payload.status
        end
    end
    return result
end

---Returns whether one stage/status observation was published.
---@param events table[]
---@param expected string
---@return boolean
local function has_observation(events, expected)
    for _, value in ipairs(observations(events)) do
        if value == expected then return true end
    end
    return false
end

describe('verified command engine conformance', function()
    it('publishes pending, fatal, failed, and timed-out gates', function()
        local pending_calls = 0
        local fixtures = {
            {name='gate-pending', timeout=4, expected='preflight:pending',
                preflight=function()
                    pending_calls = pending_calls + 1
                    return pending_calls == 1 and Outcomes.pending('waiting') or
                        Outcomes.ready(true)
                end},
            {name='gate-fatal', timeout=4, expected='preflight:fatal',
                preflight=function() return Outcomes.fatal('invalid') end},
            {name='gate-timeout', timeout=2, expected='preflight:timed_out',
                preflight=function() return Outcomes.pending('waiting') end},
        }
        for _, case in ipairs(fixtures) do
            local definition = {name=case.name, kind=CommandKind.QUERY,
                normalize=function() return {} end,
                preflight=case.preflight,
                execute=function() return Outcomes.ready(true) end,
                execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}
            local harness = Harness.new({default_timeout_ms=case.timeout})
            harness:register(fixture(definition, {case.expected}))
            pcall(function() harness:invoke(case.name) end)
            assert.is_true(has_observation(harness:events(), case.expected),
                case.expected)
        end

        local failed = {name='attempt-failed', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() error('native failure') end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
        local harness = Harness.new()
        harness:register(fixture(failed, {'attempt:failed'}))
        pcall(function() harness:invoke('attempt-failed') end)
        assert.is_true(has_observation(harness:events(), 'attempt:failed'))
    end)

    it('qualifies every command kind with a small declared fixture', function()
        local cases = {
            {kind=CommandKind.QUERY, intrinsic=IntrinsicKind.PRIMARY_OBSERVATION},
            {kind=CommandKind.ASSERTION,
                intrinsic=IntrinsicKind.PRIMARY_OBSERVATION},
            {kind=CommandKind.ACTION,
                intrinsic=IntrinsicKind.EXECUTION_RECEIPT},
            {kind=CommandKind.STATE_SETTER,
                intrinsic=IntrinsicKind.EXECUTION_RECEIPT},
            {kind=CommandKind.FIXTURE,
                intrinsic=IntrinsicKind.EXECUTION_RECEIPT},
        }
        for index, case in ipairs(cases) do
            local name = 'conformance-' .. case.kind
            local definition = {name=name, kind=case.kind,
                normalize=function(arguments) return arguments end,
                preflight=function() return Outcomes.ready(true) end,
                execute=function()
                    if case.intrinsic == IntrinsicKind.PRIMARY_OBSERVATION then
                        return Outcomes.ready(case.kind)
                    end
                    return Outcomes.executed(case.kind, {case=index})
                end,
                execution_retry_policy='once',
                intrinsic_verification=case.intrinsic}
            local expected = {'preflight:passed', 'preflight:passed',
                'attempt:started', 'attempt:completed',
                'intrinsic_verification:passed', 'completion:completed'}
            local harness = Harness.new()
            harness:register(fixture(definition, expected))
            assert.equals(case.kind, harness:invoke(name))
            assert.same(expected, observations(harness:events()))
        end
    end)

    it('qualifies callback intrinsic and optional caller verification', function()
        local definition = {name='callback-conformance', kind=CommandKind.ACTION,
            normalize=function(arguments) return arguments end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.executed('done', {receipt=true}) end,
            verify=function() return Outcomes.ready(true, {intrinsic=true}) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK}
        local harness = Harness.new()
        harness:register(fixture(definition, {}))
        assert.equals('done', harness:invoke('callback-conformance', {}, {
            verify=function() return true end}))
        local seen = observations(harness:events())
        assert.is_truthy(table.concat(seen, ','):find(
            'intrinsic_verification:passed', 1, true))
        assert.is_truthy(table.concat(seen, ','):find(
            'caller_verification:passed', 1, true))
        local finished = harness:events()[#harness:events()].payload
        assert.equals('intrinsic_and_caller', finished.evidence_kind)
    end)

    it('publishes pending and timeout verification observations', function()
        local intrinsic_calls = 0
        local definition = {name='verification-observations',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.executed('done', {done=true}) end,
            verify=function()
                intrinsic_calls = intrinsic_calls + 1
                return intrinsic_calls == 1 and
                    Outcomes.pending('intrinsic pending') or
                    Outcomes.ready(true)
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.CALLBACK}
        local harness = Harness.new({default_timeout_ms=4})
        harness:register(fixture(definition, {}))
        pcall(function()
            harness:invoke('verification-observations', {}, {
                verify=function() return false end})
        end)
        assert.is_true(has_observation(harness:events(),
            'intrinsic_verification:pending'))
        assert.is_true(has_observation(harness:events(),
            'intrinsic_verification:passed'))
        assert.is_true(has_observation(harness:events(),
            'caller_verification:pending'))
        assert.is_true(has_observation(harness:events(),
            'caller_verification:timed_out'))
    end)

    it('qualifies workflow steps and immutable result projection', function()
        local definition = {name='workflow-conformance',
            kind=CommandKind.WORKFLOW, normalize=function(arguments)
                return {value=arguments.value}
            end, preflight=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT,
            workflow={steps={{name='observe', kind=CommandKind.QUERY,
                preflight=function() return Outcomes.ready(true) end,
                execute=function(_, state)
                    return Outcomes.ready(state.request.value)
                end, execution_retry_policy='once',
                intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}},
                result=function(state)
                    return {projected=state.outputs.observe.value}
                end}}
        local harness = Harness.new()
        harness:register(fixture(definition, {}))
        local result = harness:invoke('workflow-conformance', {value='stable'})
        assert.equals('stable', result.projected)
        local child
        for _, event in ipairs(harness:events()) do
            if event.payload.name == 'workflow-conformance.observe' then
                child = event.payload.command
                break
            end
        end
        assert.is_truthy(child)
        assert.is_truthy(child.parent_invocation_id)
        assert.equals(child.root_invocation_id,
            harness:events()[1].payload.command.root_invocation_id)
    end)

    it('qualifies explicit retry with one deadline and attempt evidence', function()
        local attempts = 0
        local definition = {name='retry-conformance', kind=CommandKind.ACTION,
            normalize=function(arguments) return arguments end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                attempts = attempts + 1
                if attempts == 1 then
                    return Outcomes.retry('retry requested', {attempt=1})
                end
                return Outcomes.executed('done', {attempt=2})
            end,
            operation_key=function() return 'stable-operation' end,
            retry_safety={stable_operation_key='stable normalized identity',
                idempotency_guarantee='one logical effect per key',
                attempt_receipt_policy='every retry has a receipt',
                effect_receipt_policy='effects identify cleanup data',
                conformance_fixture='verified command engine conformance'},
            execution_retry_policy='explicit_retry_safe',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
        local harness = Harness.new({default_timeout_ms=20})
        harness:register(fixture(definition, {}))
        assert.equals('done', harness:invoke('retry-conformance'))
        assert.equals(2, attempts)
        local events = harness:events()
        local finished = events[#events].payload
        assert.equals(2, finished.attempt_count)
        assert.equals('execution_receipt_only', finished.evidence_kind)
        assert.equals('stable-operation', finished.operation_key)
        assert.is_true(harness:now_ms() < finished.configured_timeout_ms)
    end)

    it('rejects effect-absence evidence outside intrinsic verification',
            function()
        local absent = function()
            return Outcomes.effect_absent('gone', {absent_resources={{
                resource_kind='item', resource_identity='item-1'}}})
        end
        local preflight = {name='absent-preflight', kind=CommandKind.QUERY,
            normalize=function() return {} end, preflight=absent,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}
        local harness = Harness.new()
        harness:register(fixture(preflight, {}))
        assert.has_error(function() harness:invoke('absent-preflight') end)

        local caller = {name='absent-caller', kind=CommandKind.QUERY,
            normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.ready(true) end,
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}
        harness = Harness.new()
        harness:register(fixture(caller, {}))
        local succeeded, message = pcall(function()
            harness:invoke('absent-caller', {}, {verify=absent})
        end)
        assert.is_false(succeeded)
        assert.is_truthy(tostring(message):find(
            'caller verification must return a boolean', 1, true))
    end)

    it('projects bounded domain diagnostics without replacing failure', function()
        local definition = {name='diagnostic-conformance',
            kind=CommandKind.ACTION, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function() return Outcomes.failed('native failure') end,
            diagnostics=function()
                return {subject_identity='unit:7', focus={'dwarfmode/Default'},
                    viewscreen='viewscreen_dwarfmodest'}
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
        local harness = Harness.new()
        harness:register(fixture(definition, {}))
        local succeeded, message = pcall(function()
            harness:invoke('diagnostic-conformance')
        end)
        assert.is_false(succeeded)
        assert.is_truthy(tostring(message):find('native failure', 1, true))
        local terminal = harness:events()[#harness:events()].payload
        assert.equals('unit:7', terminal.diagnostic_evidence.subject_identity)
        assert.equals('viewscreen_dwarfmodest', terminal.viewscreen)
    end)

    it('publishes attempted and verified command-lifetime cleanup', function()
        local pending = true
        local transaction = {isPending=function() return pending end,
            execute=function() pending = false return true end,
            state=function() return pending and 'pending' or 'complete' end}
        local cleanup_service = {begin_mutation=function()
                return {release=function() end}
            end, register=function() return transaction end,
            pendingCommandTransactions=function() return {transaction} end,
            quarantineAmbiguousEffect=function() end}
        local definition = {name='cleanup-observations',
            kind=CommandKind.FIXTURE, normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            claims=function() return {} end,
            execute=function()
                return Outcomes.executed('done', {done=true}, {item='item-1'})
            end,
            cleanup={lifetime='command', resources=function() return {} end,
                restore=function() end, verify=function() return true end},
            execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
        local harness = Harness.new({cleanup_service=cleanup_service})
        harness:register(fixture(definition, {}))
        assert.equals('done', harness:invoke('cleanup-observations'))
        assert.is_true(has_observation(harness:events(),
            'command_cleanup:attempted'))
        assert.is_true(has_observation(harness:events(),
            'command_cleanup:verified'))
        local terminal = harness:events()[#harness:events()].payload
        assert.is_true(terminal.cleanup_evidence[1].verified)
    end)

    it('classifies an execution return after its deadline as timed out',
            function()
        local harness = Harness.new({default_timeout_ms=1})
        local definition = {name='execution-overrun', kind=CommandKind.ACTION,
            normalize=function() return {} end,
            preflight=function() return Outcomes.ready(true) end,
            execute=function()
                harness:advance_ms(1)
                return Outcomes.executed('late', {returned=true})
            end, execution_retry_policy='once',
            intrinsic_verification=IntrinsicKind.EXECUTION_RECEIPT}
        harness:register(fixture(definition, {'attempt:timed_out'}))
        pcall(function() harness:invoke('execution-overrun') end)
        assert.is_true(has_observation(harness:events(), 'attempt:timed_out'))
    end)
end)
