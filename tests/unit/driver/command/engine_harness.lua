-- Deterministic fake-clock and fake-scheduler harness for command qualification.

local Registry = require('dwarfspec.driver.command.registry')
local Runner = require('dwarfspec.driver.command.runner')

---@class dwarfspec.tests.CommandEngineHarness
---@field private _now integer
---@field private _registry dwarfspec.CommandRegistry
---@field private _events table[]
---@field private _diagnostics table[]
---@field private _runner dwarfspec.CommandRunner
local Harness = {}
Harness.__index = Harness

---Creates an isolated command engine with deterministic time and scheduling.
---@param options? table
---@return dwarfspec.tests.CommandEngineHarness
function Harness.new(options)
    options = options or {}
    local self = setmetatable({_now=options.now_ms or 0,
        _registry=Registry.new(), _events={}, _diagnostics={}}, Harness)
    local dependencies = {
        now_ms=function() return self._now end,
        wait=function(remaining_ms)
            self._now = self._now + math.min(1, remaining_ms)
        end,
        cancellation=options.cancellation or function() return false end,
        owner=function()
            return {owner_scope='test_attempt', service_run_id='run',
                suite_execution_id='suite', test_attempt_id='attempt',
                repeat_index=1, spec_file_identity='synthetic_spec.lua',
                test_identity='synthetic qualification'}
        end,
        cleanup_checkpoint=function() return 0 end,
        new_cancellation=function() return function() return false end end,
        invoke_readonly=function() end,
        record_diagnostic=function(kind, value)
            self._diagnostics[#self._diagnostics + 1] = {kind=kind, value=value}
        end,
        assert_cleanup_executable=function() end,
        resolve_mount=function() end,
        resolve_target=function(identity)
            return {stable_identity=identity}
        end,
        lookup_claim=function() end,
        capture_render=options.capture_render or function() return 0 end,
        observe_render=options.observe_render or function() end,
        wait_frames=function() end,
        wait_ticks=function() end,
        wait_event=function() end,
        wait_until=function() end,
        execute_step=function() end,
        remaining_ms=function() return 1 end,
        publish=function(kind, payload)
            self._events[#self._events + 1] = {kind=kind, payload=payload}
        end,
    }
    self._runner = Runner.new({registry=self._registry,
        default_timeout_ms=options.default_timeout_ms or 10,
        dependencies=dependencies,
        resource_index=options.resource_index or {
            validate_plan=function() return {} end},
        cleanup_service=options.cleanup_service or {begin_mutation=function()
            return {release=function() end}
        end, quarantineAmbiguousEffect=function() end}})
    return self
end

---Registers one fixture after checking its explicit qualification declaration.
---@param fixture table
function Harness:register(fixture)
    assert(type(fixture) == 'table', 'command fixture must be a table')
    for _, field in ipairs({'gate', 'execution', 'intrinsic', 'timeout',
            'retry_safety', 'cleanup', 'expected_observations'}) do
        assert(fixture[field] ~= nil,
            'command fixture requires qualification field: ' .. field)
    end
    assert(type(fixture.definition) == 'table',
        'command fixture requires a definition')
    self._registry:register_builtin(fixture.definition)
end

---Invokes one registered fixture command.
---@param name string
---@param arguments? table
---@param options? table
---@return any
function Harness:invoke(name, arguments, options)
    return self._runner:invoke(name, arguments or {}, options)
end

---Returns the mutable-free event observation list for test assertions.
---@return table[]
function Harness:events()
    local result = {}
    for index, event in ipairs(self._events) do result[index] = event end
    return result
end

---Returns the current deterministic clock value.
---@return integer
function Harness:now_ms()
    return self._now
end

---Advances the deterministic monotonic clock without scheduling a wait.
---@param elapsed_ms integer
function Harness:advance_ms(elapsed_ms)
    assert(type(elapsed_ms) == 'number' and elapsed_ms >= 0 and
        elapsed_ms % 1 == 0, 'fake clock advance must be nonnegative integer')
    self._now = self._now + elapsed_ms
end

return Harness
