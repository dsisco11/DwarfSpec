-- Structural capability-boundary tests for verified command contexts.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Context = require('dwarfspec.driver.command.context')

---Creates one complete injected capability set with observable calls.
---@return table dependencies
---@return table calls
local function dependencies()
    local calls = {}
    return {
        now_ms=function() return 25 end,
        remaining_ms=function() return 75 end,
        cancellation=function() return false, nil end,
        resolve_mount=function(value) return 'mount:' .. value end,
        resolve_target=function(value) return 'target:' .. value end,
        lookup_claim=function(value) return {claim_id=value} end,
        capture_render=function() return 7 end,
        observe_render=function(value) return value == 7 end,
        record_diagnostic=function(kind, evidence)
            calls.diagnostic = {kind=kind, evidence=evidence}
            return evidence
        end,
        invoke_readonly=function(kind, name)
            calls.nested = {kind=kind, name=name}
            return 'nested-result'
        end,
        wait_frames=function(count, remaining)
            calls.frames = {count, remaining}
            return count
        end,
        wait_ticks=function(count, remaining)
            calls.ticks = {count, remaining}
            return count
        end,
        wait_event=function(event, options, remaining)
            calls.event = {event, options, remaining}
            return {event=event}
        end,
        wait_until=function(description, predicate, remaining)
            calls.predicate = {description, remaining}
            return predicate()
        end,
        execute_step=function(step, state)
            calls.step = {step, state}
            return 'step-result'
        end,
    }, calls
end

---Creates one valid test-attempt command identity.
---@return table
local function identity()
    return {
        invocation_id='invocation-2',
        root_invocation_id='invocation-1',
        parent_invocation_id='invocation-1',
        owner_scope='test_attempt',
        service_run_id='run-1',
        suite_execution_id='suite-1',
        test_attempt_id='attempt-1',
        target_identity='target-7',
        cleanup_checkpoint=4,
    }
end

---Creates context construction options for one callback stage.
---@param stage string
---@param injected? table
---@return table
local function options(stage, injected)
    return {
        stage=stage,
        identity=identity(),
        dependencies=injected or dependencies(),
    }
end

describe('CommandReadContext', function()
    it('exposes only immutable observation capabilities', function()
        local injected, calls = dependencies()
        local context = Context.new_read(options('preflight', injected))
        assert.equals(25, context:now_ms())
        assert.equals(75, context:remaining_ms())
        assert.same({false, nil}, {context:cancellation()})
        assert.equals('mount:value', context:resolve_mount('value'))
        assert.equals('target:value', context:resolve_target('value'))
        assert.equals('claim-1', context:lookup_claim('claim-1').claim_id)
        assert.equals(7, context:capture_render())
        assert.is_true(context:observe_render(7))
        context:record_diagnostic('target', {id='target-7'})
        assert.equals('target', calls.diagnostic.kind)
        assert.equals('target-7', calls.diagnostic.evidence.id)
        assert.equals('nested-result', context:invoke_readonly(
            CommandKind.QUERY, 'getTick'))
        assert.is_nil(context.wait_frames)
        assert.is_nil(context.cleanup_registration)
        assert.is_nil(context._dependencies)
        assert.has_error(function() context.extra = true end)
    end)

    it('returns immutable ancestry, ownership, target, checkpoint, and stage',
            function()
        local context = Context.new_read(options('claim_planning'))
        local command = context:identity()
        assert.equals('invocation-2', command.invocation_id)
        assert.equals('invocation-1', command.root_invocation_id)
        assert.equals('invocation-1', command.parent_invocation_id)
        assert.equals('test_attempt', command.owner_scope)
        assert.equals('target-7', command.target_identity)
        assert.equals(4, command.cleanup_checkpoint)
        assert.equals('claim_planning', command.current_stage)
        assert.has_error(function() command.current_stage = 'execution' end)
        local guard = Context.StageGuard.new(function() return 'execution' end)
        local mismatched = options('preflight')
        mismatched.guard = guard
        assert.has_error(function() Context.new_read(mismatched) end)
    end)
end)

describe('CommandExecutionContext', function()
    it('adds only cooperative waits and internal step execution', function()
        local injected, calls = dependencies()
        local context = Context.new_execution(options('execution', injected))
        assert.equals(2, context:wait_frames(2))
        assert.equals(3, context:wait_ticks(3))
        assert.equals('saved', context:wait_event('saved').event)
        assert.equals('ready', context:wait_until('ready',
            function() return 'ready' end))
        assert.equals('step-result', context:execute_step(
            {name='step'}, {outputs={}}))
        assert.same({2, 75}, calls.frames)
        assert.same({3, 75}, calls.ticks)
        assert.equals(75, calls.event[3])
        assert.equals(75, calls.predicate[2])
        assert.is_nil(context.cleanup_registration)
        assert.is_nil(context.register_cleanup)
        assert.is_nil(context.activate_claim)
        assert.is_nil(context.registry)
        assert.is_nil(context.host)
        assert.is_nil(context.publisher)
    end)

    it('exposes cleanup registration only in the specialized context',
            function()
        local stage = 'execution'
        local guard = Context.StageGuard.new(function() return stage end)
        local received
        local capability = Context.CleanupRegistrationCapability.new(
            function(registration)
                received = registration
                return 'transaction-1'
            end, guard)
        local context = Context.new_privileged_execution(
            options('execution'), capability)
        assert.equals('transaction-1',
            context:cleanup_registration():register({label='restore'}))
        assert.equals('restore', received.label)
        assert.is_nil(capability._register)
        assert.has_error(function() capability.extra = true end)
        stage = 'intrinsic_verification'
        assert.has_error(function()
            capability:register({label='forbidden'})
        end)
    end)
end)

describe('command lifecycle stage guard', function()
    it('allows top-level commands and only read-only nested commands', function()
        local stage = 'test_body'
        local guard = Context.StageGuard.new(function() return stage end)
        guard:assert_public_command(CommandKind.ACTION)
        stage = 'preflight'
        guard:assert_public_command(CommandKind.QUERY)
        guard:assert_public_command(CommandKind.ASSERTION)
        assert.has_error(function()
            guard:assert_public_command(CommandKind.ACTION)
        end)
        stage = 'cleanup_verification'
        guard:assert_public_command(CommandKind.QUERY)
        stage = 'claim_planning'
        assert.has_error(function()
            guard:assert_public_command(CommandKind.QUERY)
        end)
        stage = 'execution'
        assert.has_error(function()
            guard:assert_public_command(CommandKind.QUERY)
        end)
        stage = 'test_body'
        assert.has_error(function()
            guard:assert_public_command('unknown')
        end)
    end)

    it('prevents captured cleanup handles bypassing restricted stages',
            function()
        local stage = 'test_body'
        local guard = Context.StageGuard.new(function() return stage end)
        local handle = {}
        ---Executes a synthetic mutable handle behind the central guard.
        function handle:execute()
            guard:assert_cleanup_handle_execution()
            return true
        end
        for _, allowed in ipairs({
            'suite_setup', 'suite_teardown', 'test_setup', 'test_body',
            'test_teardown', 'runner', 'finalizer',
        }) do
            stage = allowed
            assert.is_true(handle:execute())
        end
        for _, forbidden in ipairs({
            'normalization', 'preflight', 'claim_planning', 'execution',
            'workflow', 'intrinsic_verification', 'caller_verification',
            'cleanup_restore', 'cleanup_verification',
        }) do
            stage = forbidden
            assert.has_error(function() handle:execute() end)
        end
    end)
end)
