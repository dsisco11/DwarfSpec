local CleanupRegistrationService = require(
    'dwarfspec.driver.cleanup.cleanup_registration_service')
local Registry = require('dwarfspec.driver.command.registry')
local ResourceDependencyIndex = require(
    'dwarfspec.driver.command.resource_dependency_index')
local Runner = require('dwarfspec.driver.command.runner')
local SetGamePaused = require(
    'dwarfspec.driver.builtins.set_game_paused')
local SetGameSpeed = require(
    'dwarfspec.driver.builtins.set_game_speed')

---@class dwarfspec.tests.StateSetterFixture
---@field now integer
---@field state boolean
---@field reads integer
---@field block_verification boolean
---@field restore_failure string|nil
---@field owner table
---@field index dwarfspec.ResourceDependencyIndex
---@field cleanup dwarfspec.CleanupRegistrationService
---@field runner dwarfspec.CommandRunner
local Fixture = {}
Fixture.__index = Fixture

---Creates a runner-backed representative state-setter fixture.
---@return dwarfspec.tests.StateSetterFixture
function Fixture.new()
    local self = setmetatable({now=0, state=false, reads=0,
        block_verification=false}, Fixture)
    self.owner = {owner_scope='test_attempt', service_run_id='run',
        suite_execution_id='suite', test_attempt_id='attempt', repeat_index=1,
        spec_file_identity='state_setter_spec.lua',
        test_identity='state setter conformance'}
    self.index = ResourceDependencyIndex.new('run', function()
        return 'complete'
    end)
    self.cleanup = CleanupRegistrationService.new({service_run_id='run',
        resource_index=self.index, now_ms=function() return self.now end})
    local runtime = {}
    ---Reads controlled state, optionally withholding verification readback.
    ---@return boolean
    function runtime:pause_state()
        self.fixture.reads = self.fixture.reads + 1
        if self.fixture.block_verification and self.fixture.reads >= 4 then
            return false
        end
        return self.fixture.state
    end
    ---Applies or rejects one controlled pause-state write.
    ---@param value boolean
    ---@return boolean
    function runtime:set_pause(value)
        if not value and self.fixture.restore_failure then
            error(self.fixture.restore_failure)
        end
        self.fixture.state = value
        return true
    end
    runtime.fixture = self
    local registry = Registry.new()
    registry:register_builtin(SetGamePaused.new(runtime):definition())
    local dependencies = {
        now_ms=function() return self.now end,
        wait=function() self.now = self.now + 1 end,
        cancellation=function() return false, nil end,
        owner=function() return self.owner end,
        cleanup_checkpoint=function() return 0 end,
        new_cancellation=function() return function() return false end end,
        invoke_readonly=function() end,
        record_diagnostic=function() end,
        assert_cleanup_executable=function() end,
        resolve_mount=function() end,
        resolve_target=function() end,
        lookup_claim=function() end,
        capture_render=function() return 0 end,
        observe_render=function() end,
        wait_frames=function() end,
        wait_ticks=function() end,
        wait_event=function() end,
        wait_until=function() end,
        execute_step=function() end,
        remaining_ms=function() return 1 end,
        cleanup_timeout_ms=20,
    }
    self.runner = Runner.new({registry=registry, default_timeout_ms=3,
        dependencies=dependencies, resource_index=self.index,
        cleanup_service=self.cleanup})
    return self
end

describe('state-setter family conformance', function()
    it('retains cleanup through verification expiry and manual teardown',
            function()
        local fixture = Fixture.new()
        fixture.block_verification = true

        local succeeded, failure = pcall(function()
            fixture.runner:invoke('setGamePaused', {value=true})
        end)

        assert.is_false(succeeded)
        assert.matches('intrinsic_verification:', tostring(failure), 1, true)
        assert.is_true(fixture.state)
        assert.equals(1, (function()
            local count = 0
            for _ in pairs(fixture.cleanup:pending_ids_for(
                    fixture.owner)) do
                count = count + 1
            end
            return count
        end)())
        fixture.block_verification = false
        local confirmed, result = fixture.cleanup:finalize_owner(
            fixture.owner, 'manual conformance teardown', false)
        assert.is_true(confirmed)
        assert.is_true(result.confirmed)
        assert.is_false(fixture.state)
    end)

    it('reports automatic owner-cleanup failure after command success',
            function()
        local fixture = Fixture.new()
        assert.is_true(fixture.runner:invoke(
            'setGamePaused', {value=true}))
        fixture.restore_failure = 'injected owner cleanup failure'

        local confirmed, result = fixture.cleanup:finalize_owner(
            fixture.owner, 'automatic owner teardown', false)

        assert.is_false(confirmed)
        assert.is_false(result.confirmed)
        assert.matches('injected owner cleanup failure',
            table.concat(result.failures, '\n'), 1, true)
    end)

    it('composes setter failure with independently failed owner cleanup',
            function()
        local now, state, writes = 0,
            {tps=100, graphical_rate=50, ratio=2}, 0
        local runtime = {
            speed_state=function()
                return {tps=state.tps,
                    graphical_rate=state.graphical_rate, ratio=state.ratio}
            end,
            set_speed=function(_, value)
                writes = writes + 1
                state.tps, state.ratio = value.tps, value.ratio
                if writes == 1 then error('primary speed failure') end
                error('cleanup speed failure')
            end,
        }
        local owner = {owner_scope='test_attempt', service_run_id='run',
            suite_execution_id='suite', test_attempt_id='attempt',
            repeat_index=1, spec_file_identity='state_setter_spec.lua',
            test_identity='composed failure'}
        local index = ResourceDependencyIndex.new('run', function()
            return 'complete'
        end)
        local cleanup = CleanupRegistrationService.new({service_run_id='run',
            resource_index=index, now_ms=function() return now end})
        local registry = Registry.new()
        registry:register_builtin(SetGameSpeed.new(runtime):definition())
        local dependencies = {
            now_ms=function() return now end,
            wait=function() now = now + 1 end,
            cancellation=function() return false, nil end,
            owner=function() return owner end,
            cleanup_checkpoint=function() return 0 end,
            new_cancellation=function() return function() return false end end,
            invoke_readonly=function() end, record_diagnostic=function() end,
            assert_cleanup_executable=function() end,
            resolve_mount=function() end, resolve_target=function() end,
            lookup_claim=function() end, capture_render=function() return 0 end,
            observe_render=function() end, wait_frames=function() end,
            wait_ticks=function() end, wait_event=function() end,
            wait_until=function() end, execute_step=function() end,
            remaining_ms=function() return 1 end,
        }
        local command_runner = Runner.new({registry=registry,
            default_timeout_ms=3, dependencies=dependencies,
            resource_index=index, cleanup_service=cleanup})

        local succeeded, failure = pcall(function()
            command_runner:invoke('setGameSpeed', {tps=120})
        end)

        assert.is_false(succeeded)
        assert.matches('primary speed failure', tostring(failure), 1, true)
        local confirmed, result = cleanup:finalize_owner(
            owner, 'automatic failed-command teardown', false)
        assert.is_false(confirmed)
        assert.matches('cleanup speed failure',
            table.concat(result.failures, '\n'), 1, true)
    end)
end)
