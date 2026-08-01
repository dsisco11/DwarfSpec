-- Abort, quarantine recovery, acknowledgement, and discard policy.

local events = require('dwarfspec.protocol.events')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')
local RunState = require('dwarfspec.protocol.enums.run_states')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local validation = require('dwarfspec.host.service.scheduler.request_validation')

local M = {}
local ACTIVE = {[RunState.STARTING]=true, [RunState.RUNNING]=true,
    [RunState.CLEANING]=true}
local TERMINAL = {[RunState.PASSED]=true, [RunState.FAILED]=true,
    [RunState.ABORTED]=true, [RunState.CANCELLED]=true}

---Authorizes a capability-owned active run for normal abort.
function M.authorize_abort(registry, request)
    local run = validation.authorize_owner(registry, request, 'abort')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'abort reason must be a nonempty bounded string')
    assert(registry.active_run_id == run.run_id and ACTIVE[run.state] and
        not run.terminal, 'only the active run can be aborted')
    return run
end

---Clears executor quarantine after authoritative clean-state verification.
function M.recover_executor(registry, request, context)
    assert(registry.quarantine.active,
        'automation executor is not quarantined')
    assert(type(request) == 'table',
        'executor recovery request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        'executor recovery service identity does not match')
    assert(request.run_id == registry.quarantine.run_id,
        'executor recovery run identity does not match quarantine')
    assert(request.generation == registry.quarantine.generation,
        'executor recovery generation does not match quarantine')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'executor recovery reason must be a nonempty bounded string')
    assert(type(request.proof) == 'table',
        'executor recovery requires a clean-state proof')
    events.copy_json(request.proof, 'executor recovery proof')
    assert(type(context.verify_clean_state) == 'function',
        'executor recovery requires an authoritative verifier')
    local verified, detail = context.verify_clean_state(request.proof)
    assert(verified == true, detail or
        'executor clean-state proof was rejected')
    transitions.clear_quarantine(registry)
    return {recovered=true}
end

---Acknowledges one exact owner-retained terminal result after persistence.
function M.acknowledge(registry, request, context)
    local run = validation.authorize_owner(registry, request, 'acknowledgement')
    assert(run.terminal and TERMINAL[run.state],
        'only a terminal run can be acknowledged')
    assert(run.acknowledged ~= true and run.discarded ~= true,
        'terminal run has already been released')
    local persistence = request.persistence
    assert(type(persistence) == 'table' and persistence.succeeded == true,
        'acknowledgement requires successful persistence')
    assert(persistence.policy == run.result_policy,
        'acknowledgement persistence policy does not match run')
    if run.result_policy == ResultPolicy.FILE then
        assert(persistence.result_path == run.result_path,
            'acknowledgement result path does not match run')
    end
    transitions.acknowledge(registry, run, validation.current_time(context))
    return run
end

---Releases one exact retained terminal result through operator authority.
function M.discard(registry, request, context)
    local run = validation.exact_run(registry, request, 'discard')
    assert(run.terminal and TERMINAL[run.state],
        'only a terminal run can be discarded')
    assert(run.acknowledged ~= true and run.discarded ~= true,
        'terminal run has already been released')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'discard reason must be a nonempty bounded string')
    local authority = validation.authorize_operator(context, request,
        'discard', run, {
            request='discard',
            authority='discard operator authority',
        })
    transitions.discard(registry, run, request.reason, authority,
        validation.current_time(context))
    return run
end

---Authorizes an operator recovery abort without owner impersonation.
function M.authorize_operator_abort(registry, request, context)
    local run = validation.exact_run(registry, request, 'operator abort')
    assert(registry.active_run_id == run.run_id and ACTIVE[run.state] and
        not run.terminal, 'only the active run can be force-aborted')
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'operator abort reason must be a nonempty bounded string')
    local authority = validation.authorize_operator(context, request,
        'abort', run, {
            request='operator abort',
            authority='operator abort authority',
        })
    transitions.operator_diagnostic(run, 'operator_abort', request.reason,
        authority, validation.current_time(context))
    return run
end

return M
