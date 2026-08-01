-- Queue and execution lease policy for scheduler runs.

local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local RunState = require('dwarfspec.protocol.enums.run_states')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local validation = require('dwarfspec.host.service.scheduler.request_validation')

local M = {}
local ACTIVE = {[RunState.STARTING]=true, [RunState.RUNNING]=true,
    [RunState.CLEANING]=true}

---Returns the currently renewable lease for one nonterminal run.
---@param run table
---@return table|nil
local function current_lease(run)
    if run.state == RunState.QUEUED then return run.queue_lease end
    if run.state == RunState.STARTING or run.state == RunState.RUNNING then
        return run.execution_lease
    end
    return nil
end

---Cancels and invalidates one scheduler-owned lease timer.
---@param run table
---@param context table|nil
function M.cancel_timer(run, context)
    local timer_id = transitions.detach_lease_timer(run)
    if timer_id ~= nil and context and
            type(context.cancel_lease_timer) == 'function' then
        context.cancel_lease_timer(timer_id)
    end
end

local arm_timer

---Handles one exact lease-timer callback and ignores stale generations.
---@param registry table
---@param run_id string
---@param generation integer
---@param timer_generation integer
---@param context table
function M.timer_fired(registry, run_id, generation, timer_generation,
        context)
    local run = registry.runs[run_id]
    if run == nil or run.generation ~= generation or
            run.lease_timer_generation ~= timer_generation then
        return
    end
    transitions.clear_fired_lease_timer(run)
    local ok, failure = xpcall(function()
        if run.owner_kind == OwnerKind.IN_PROCESS and
                run.execution_lease.active then
            M.heartbeat(registry, {
                service_instance_id=registry.service_instance_id,
                project_id=run.project_id,
                run_id=run.run_id,
                generation=run.generation,
            }, context)
            arm_timer(registry, run, context)
            return
        end
        assert(type(context.expire_leases) == 'function',
            'lease timer requires the service expiry boundary')
        context.expire_leases()
        if registry.runs[run_id] == run and not run.terminal then
            arm_timer(registry, run, context)
        end
    end, debug.traceback)
    if not ok then transitions.record_lease_timer_error(run, failure) end
end

---Replaces the timer for one currently renewable lease.
---@param registry table
---@param run table
---@param context table|nil
arm_timer = function(registry, run, context)
    M.cancel_timer(run, context)
    local lease = current_lease(run)
    if lease == nil or not lease.active or not context or
            type(context.schedule_lease_timer) ~= 'function' then
        return
    end
    local timestamp_ms = validation.current_time(context)
    local delay_ms
    if run.owner_kind == OwnerKind.IN_PROCESS then
        delay_ms = math.max(1, math.floor(lease.timeout_ms / 2))
    else
        delay_ms = math.max(1, lease.expires_at_ms - timestamp_ms)
    end
    local timer_generation = run.lease_timer_generation
    local timer_id = context.schedule_lease_timer(run, delay_ms, function()
        M.timer_fired(registry, run.run_id, run.generation,
            timer_generation, context)
    end)
    transitions.attach_lease_timer(run, timer_id)
end

M.arm_timer = arm_timer

---Renews the applicable external queue or execution lease.
function M.renew(registry, request, context)
    local run = validation.authorize_owner(registry, request, 'lease renewal')
    assert(run.owner_kind == OwnerKind.EXTERNAL,
        'only an external owner renews a caller lease')
    assert(not run.terminal, 'a terminal run does not own a renewable lease')
    local lease
    if run.state == RunState.QUEUED then lease = run.queue_lease
    elseif ACTIVE[run.state] then lease = run.execution_lease
    else error('run state does not own a renewable lease') end
    transitions.renew_lease(lease, validation.current_time(context))
    return run
end

---Renews one service-owned in-process execution heartbeat.
function M.heartbeat(registry, request, context)
    assert(type(request) == 'table',
        'service heartbeat request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        'service heartbeat service identity does not match')
    local run = assert(registry.runs[request.run_id],
        'automation run was not found: ' .. tostring(request.run_id))
    assert(run.project_id == request.project_id,
        'service heartbeat project identity does not match run')
    assert(run.generation == request.generation,
        'service heartbeat generation does not match run')
    validation.run_identity(registry, run)
    assert(run.owner_kind == OwnerKind.IN_PROCESS,
        'service heartbeat requires an in-process-owned run')
    assert(ACTIVE[run.state] and not run.terminal,
        'service heartbeat requires an active run')
    local lease = run.execution_lease
    assert(lease.active and lease.service_owned,
        'in-process execution lease is not active')
    local timestamp_ms = validation.current_time(context)
    transitions.heartbeat(lease, timestamp_ms)
    return run
end

---Claims one expired active external lease for emergency abort.
function M.claim_expired_active(registry, context)
    if not registry.active_run_id then return nil end
    local run = assert(registry.runs[registry.active_run_id],
        'active executor references an unknown run')
    local lease = run.execution_lease
    if run.owner_kind ~= OwnerKind.EXTERNAL or not lease.active or
            validation.current_time(context) < lease.expires_at_ms then
        return nil
    end
    transitions.claim_expired(run)
    return run
end

return M
