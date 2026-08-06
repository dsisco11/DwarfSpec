-- Stage-restricted capability objects for verified command callbacks.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local Diagnostics = require('dwarfspec.driver.command.diagnostics')
local Schemas = require('dwarfspec.protocol.verified_execution_schemas')

---@class dwarfspec.CommandContextFactory
local Context = {}

local CONTEXT_STATE = setmetatable({}, {__mode='k'})
local GUARD_STATE = setmetatable({}, {__mode='k'})
local CAPABILITY_STATE = setmetatable({}, {__mode='k'})

---@class dwarfspec.CommandReadContext
---@field private _dependencies table
---@field private _identity table
---@field private _guard dwarfspec.CommandStageGuard
local ReadContext = {}
ReadContext.__index = ReadContext

---@class dwarfspec.CommandExecutionContext: dwarfspec.CommandReadContext
local ExecutionContext = setmetatable({}, {__index=ReadContext})
ExecutionContext.__index = ExecutionContext

---@class dwarfspec.PrivilegedCommandExecutionContext: dwarfspec.CommandExecutionContext
---@field private _cleanup_registration dwarfspec.CleanupRegistrationCapability
local PrivilegedExecutionContext = setmetatable({}, {__index=ExecutionContext})
PrivilegedExecutionContext.__index = PrivilegedExecutionContext

---@class dwarfspec.CleanupRegistrationCapability
---@field private _register fun(registration: table): any
---@field private _guard dwarfspec.CommandStageGuard
local CleanupRegistrationCapability = {}
CleanupRegistrationCapability.__index = CleanupRegistrationCapability

---@class dwarfspec.CommandStageGuard
---@field private _current_stage fun(): string
local StageGuard = {}
StageGuard.__index = StageGuard

---@class dwarfspec.driver.command.ContextInternals
local Internals = {}

---Creates an immutable capability object with hidden framework state.
---@param class table
---@param state table
---@param state_map table
---@param label string
---@return table
function Internals.instance(class, state, state_map, label)
    local instance = setmetatable({}, {
        __index=class,
        __newindex=function() error(label .. ' is immutable', 2) end,
        __metatable=false,
    })
    state_map[instance] = state
    return instance
end

---Returns hidden state for one context object.
---@param context table
---@return table
function Internals.context_state(context)
    local state = CONTEXT_STATE[context]
    assert(state, 'invalid command context')
    return state
end

---Returns hidden state for one stage guard.
---@param guard table
---@return table
function Internals.guard_state(guard)
    local state = GUARD_STATE[guard]
    assert(state, 'invalid command stage guard')
    return state
end

---Returns hidden state for one cleanup-registration capability.
---@param capability table
---@return table
function Internals.capability_state(capability)
    local state = CAPABILITY_STATE[capability]
    assert(state, 'invalid cleanup registration capability')
    return state
end

Internals.READ_STAGES = {
    preflight=true,
    intrinsic_verification=true,
    caller_verification=true,
    cleanup_verification=true,
}

Internals.PUBLIC_STAGES = {
    suite_setup=true,
    suite_teardown=true,
    test_setup=true,
    test_body=true,
    test_teardown=true,
}

Internals.CLEANUP_EXECUTION_STAGES = {
    suite_setup=true,
    suite_teardown=true,
    test_setup=true,
    test_body=true,
    test_teardown=true,
    runner=true,
    finalizer=true,
}

Internals.COMMAND_STAGES = {
    normalization=true,
    preflight=true,
    claim_planning=true,
    execution=true,
    workflow=true,
    intrinsic_verification=true,
    caller_verification=true,
    cleanup_restore=true,
    cleanup_verification=true,
}

---Requires one injected callback.
---@param dependencies table
---@param name string
---@return function
function Internals.callback(dependencies, name)
    local callback = dependencies[name]
    assert(type(callback) == 'function',
        'command context requires ' .. name .. ' callback')
    return callback
end

---Returns whether a value is one supported command kind.
---@param kind any
---@return boolean
function Internals.command_kind(kind)
    for _, candidate in pairs(CommandKind) do
        if kind == candidate then return true end
    end
    return false
end

---Validates and freezes command invocation identity data.
---@param identity table
---@param stage string
---@return table
function Internals.identity(identity, stage)
    assert(type(identity) == 'table', 'command identity must be a table')
    Schemas.new():validate_command_identity(identity)
    assert(Internals.COMMAND_STAGES[stage],
        'command context has unsupported stage')
    assert(type(identity.cleanup_checkpoint) == 'number' and
        identity.cleanup_checkpoint >= 0 and
        identity.cleanup_checkpoint % 1 == 0,
        'command identity requires a nonnegative cleanup_checkpoint')
    if identity.target_identity ~= nil then
        assert(type(identity.target_identity) == 'string' and
            identity.target_identity ~= '',
            'command target_identity must be a nonempty string')
    end
    local copy = {}
    for key, value in pairs(identity) do copy[key] = value end
    copy.current_stage = stage
    return Diagnostics.new():sanitize(copy, 'command identity')
end

---Creates a dynamic lifecycle-stage guard.
---@param current_stage fun(): string
---@return dwarfspec.CommandStageGuard
function StageGuard.new(current_stage)
    assert(type(current_stage) == 'function',
        'stage guard requires a current_stage callback')
    return Internals.instance(StageGuard, {_current_stage=current_stage},
        GUARD_STATE, 'command stage guard')
end

---Returns the currently active lifecycle stage.
---@return string
function StageGuard:stage()
    local stage = Internals.guard_state(self)._current_stage()
    assert(type(stage) == 'string' and stage ~= '',
        'current lifecycle stage must be a nonempty string')
    return stage
end

---Guards public command entry and nested read-only invocation.
---@param kind string
function StageGuard:assert_public_command(kind)
    assert(Internals.command_kind(kind),
        'public command kind is unsupported')
    local stage = self:stage()
    if Internals.PUBLIC_STAGES[stage] then return end
    if Internals.READ_STAGES[stage] and
            (kind == CommandKind.QUERY or kind == CommandKind.ASSERTION) then
        return
    end
    error(('public %s command is forbidden during %s')
        :format(tostring(kind), stage), 2)
end

---Guards manual execution of a captured mutable cleanup handle.
function StageGuard:assert_cleanup_handle_execution()
    local stage = self:stage()
    assert(Internals.CLEANUP_EXECUTION_STAGES[stage],
        'cleanup handle execution is forbidden during ' .. stage)
end

---Guards the privileged cleanup-registration mutation boundary.
function StageGuard:assert_cleanup_registration()
    local stage = self:stage()
    assert(stage == 'execution',
        'cleanup registration capability is forbidden during ' .. stage)
end

---Creates the runner-owned atomic cleanup-registration capability.
---@param register fun(registration: table): any
---@param guard dwarfspec.CommandStageGuard
---@return dwarfspec.CleanupRegistrationCapability
function CleanupRegistrationCapability.new(register, guard)
    assert(type(register) == 'function',
        'cleanup registration capability requires register callback')
    assert(GUARD_STATE[guard] ~= nil,
        'cleanup registration capability requires a stage guard')
    return Internals.instance(CleanupRegistrationCapability, {
        _register=register, _guard=guard,
    }, CAPABILITY_STATE, 'cleanup registration capability')
end

---Atomically registers one post-effect transaction and its claims.
---@param registration table
---@return any
function CleanupRegistrationCapability:register(registration)
    local state = Internals.capability_state(self)
    state._guard:assert_cleanup_registration()
    assert(type(registration) == 'table',
        'cleanup registration must be a table')
    return state._register(registration)
end

---Creates validated base storage for a callback context.
---@param options table
---@return table
function Internals.context_values(options)
    assert(type(options) == 'table', 'command context options are required')
    assert(type(options.dependencies) == 'table',
        'command context dependencies are required')
    assert(type(options.stage) == 'string',
        'command context stage is required')
    local dependencies = options.dependencies
    Internals.callback(dependencies, 'now_ms')
    Internals.callback(dependencies, 'remaining_ms')
    Internals.callback(dependencies, 'cancellation')
    Internals.callback(dependencies, 'resolve_mount')
    Internals.callback(dependencies, 'resolve_target')
    Internals.callback(dependencies, 'lookup_claim')
    Internals.callback(dependencies, 'capture_render')
    Internals.callback(dependencies, 'observe_render')
    Internals.callback(dependencies, 'record_diagnostic')
    local guard = options.guard or StageGuard.new(function()
        return options.stage
    end)
    assert(GUARD_STATE[guard] ~= nil,
        'command context guard must be a CommandStageGuard')
    assert(guard:stage() == options.stage,
        'command context stage must match its active stage guard')
    return {
        _dependencies=dependencies,
        _identity=Internals.identity(options.identity, options.stage),
        _guard=guard,
    }
end

---Returns the monotonic timestamp in milliseconds.
---@return number
function ReadContext:now_ms()
    local value = Internals.context_state(self)._dependencies.now_ms()
    assert(type(value) == 'number' and value == value and
        value > -math.huge and value < math.huge,
        'command monotonic clock must return a finite number')
    return value
end

---Returns whole milliseconds remaining on the inherited deadline.
---@return integer
function ReadContext:remaining_ms()
    local value = Internals.context_state(self)._dependencies.remaining_ms()
    assert(type(value) == 'number' and value >= 0 and value % 1 == 0 and
        value < math.huge,
        'command deadline must return nonnegative finite whole milliseconds')
    return value
end

---Returns cancellation state and its optional bounded reason.
---@return boolean cancelled
---@return string|nil reason
function ReadContext:cancellation()
    local cancelled, reason =
        Internals.context_state(self)._dependencies.cancellation()
    assert(type(cancelled) == 'boolean',
        'command cancellation state must be boolean')
    assert(reason == nil or type(reason) == 'string',
        'command cancellation reason must be a string')
    if reason ~= nil then
        reason = Diagnostics.new():sanitize(reason,
            'command cancellation reason')
    end
    return cancelled, reason
end

---Resolves the current mount through its injected read-only adapter.
---@param ... any
---@return any
function ReadContext:resolve_mount(...)
    return Internals.context_state(self)._dependencies.resolve_mount(...)
end

---Re-resolves a stable target through its injected read-only adapter.
---@param ... any
---@return any
function ReadContext:resolve_target(...)
    return Internals.context_state(self)._dependencies.resolve_target(...)
end

---Looks up one active resource claim without exposing index mutation.
---@param reference any
---@return any
function ReadContext:lookup_claim(reference)
    local value = Internals.context_state(self)._dependencies.lookup_claim(
        reference)
    if value == nil then return nil end
    return Diagnostics.new():sanitize(value, 'resource claim observation')
end

---Captures the current render generation for later observation.
---@return any
function ReadContext:capture_render()
    return Internals.context_state(self)._dependencies.capture_render()
end

---Observes render state relative to a prior captured generation.
---@param generation any
---@return any
function ReadContext:observe_render(generation)
    return Internals.context_state(self)._dependencies.observe_render(generation)
end

---Records one already-bounded diagnostic observation.
---@param kind string
---@param evidence table
---@return any
function ReadContext:record_diagnostic(kind, evidence)
    assert(type(kind) == 'string' and kind ~= '',
        'diagnostic kind must be a nonempty string')
    assert(type(evidence) == 'table', 'diagnostic evidence must be a table')
    local bounded = Diagnostics.new():sanitize(evidence,
        'command context diagnostic')
    Internals.context_state(self)._dependencies.record_diagnostic(kind, bounded)
    return bounded
end

---Returns immutable invocation, ancestry, owner, target, and stage identity.
---@return table
function ReadContext:identity()
    return Internals.context_state(self)._identity
end

---Invokes a nested public query or assertion under the current read stage.
---@param kind string
---@param name string
---@param ... any
---@return any
function ReadContext:invoke_readonly(kind, name, ...)
    local state = Internals.context_state(self)
    state._guard:assert_public_command(kind)
    assert(type(name) == 'string' and name ~= '',
        'nested command name must be a nonempty string')
    return Internals.callback(state._dependencies, 'invoke_readonly')(
        kind, name, ...)
end

---Cooperatively waits for an exact number of rendered frames.
---@param count integer
---@return any
function ExecutionContext:wait_frames(count)
    return Internals.callback(Internals.context_state(self)._dependencies,
        'wait_frames')(
        count, self:remaining_ms())
end

---Cooperatively waits for an exact number of simulation ticks.
---@param count integer
---@return any
function ExecutionContext:wait_ticks(count)
    return Internals.callback(Internals.context_state(self)._dependencies,
        'wait_ticks')(
        count, self:remaining_ms())
end

---Cooperatively waits for one named event occurrence.
---@param event string
---@param options? table
---@return any
function ExecutionContext:wait_event(event, options)
    return Internals.callback(Internals.context_state(self)._dependencies,
        'wait_event')(
        event, options, self:remaining_ms())
end

---Cooperatively polls a predicate within the inherited deadline.
---@param description string
---@param predicate fun(): any
---@return any
function ExecutionContext:wait_until(description, predicate)
    return Internals.callback(Internals.context_state(self)._dependencies,
        'wait_until')(
        description, predicate, self:remaining_ms())
end

---Executes one validated internal workflow step under parent ownership.
---@param step table
---@param state table
---@return any
function ExecutionContext:execute_step(step, state)
    return Internals.callback(Internals.context_state(self)._dependencies,
        'execute_step')(step, state)
end

---Returns the specialized cleanup-registration capability.
---@return dwarfspec.CleanupRegistrationCapability
function PrivilegedExecutionContext:cleanup_registration()
    return Internals.context_state(self)._cleanup_registration
end

---Creates an observation-only command context.
---@param options table
---@return dwarfspec.CommandReadContext
function Context.new_read(options)
    return Internals.instance(ReadContext, Internals.context_values(options),
        CONTEXT_STATE, 'command read context')
end

---Creates a command context with cooperative execution capabilities.
---@param options table
---@return dwarfspec.CommandExecutionContext
function Context.new_execution(options)
    local values = Internals.context_values(options)
    Internals.callback(values._dependencies, 'wait_frames')
    Internals.callback(values._dependencies, 'wait_ticks')
    Internals.callback(values._dependencies, 'wait_event')
    Internals.callback(values._dependencies, 'wait_until')
    Internals.callback(values._dependencies, 'execute_step')
    return Internals.instance(ExecutionContext, values, CONTEXT_STATE,
        'command execution context')
end

---Creates the registerCleanup definition's specialized execution context.
---@param options table
---@param capability dwarfspec.CleanupRegistrationCapability
---@return dwarfspec.PrivilegedCommandExecutionContext
function Context.new_privileged_execution(options, capability)
    assert(CAPABILITY_STATE[capability] ~= nil,
        'privileged context requires CleanupRegistrationCapability')
    local values = Internals.context_values(options)
    Internals.callback(values._dependencies, 'wait_frames')
    Internals.callback(values._dependencies, 'wait_ticks')
    Internals.callback(values._dependencies, 'wait_event')
    Internals.callback(values._dependencies, 'wait_until')
    Internals.callback(values._dependencies, 'execute_step')
    values._cleanup_registration = capability
    return Internals.instance(PrivilegedExecutionContext, values,
        CONTEXT_STATE, 'privileged command execution context')
end

Context.StageGuard = StageGuard
Context.CleanupRegistrationCapability = CleanupRegistrationCapability

return Context
