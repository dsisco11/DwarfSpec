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
    if registry.active_run_id ~= run.run_id or not ACTIVE[run.state] or
            run.terminal then
        validation.reject('invalid_run_state',
            'Only the active run can be aborted.', {
                operation='abort', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
    return run
end

---Clears executor quarantine after authoritative clean-state verification.
function M.recover_executor(registry, request, context)
    assert(type(request) == 'table',
        'executor recovery request must be a table')
    assert(request.service_instance_id == registry.service_instance_id,
        'executor recovery service identity does not match')
    if not registry.quarantine.active then
        validation.reject('invalid_run_state',
            'The DwarfSpec executor is not quarantined.', {
                operation='recover executor', run_id=request.run_id,
                generation=request.generation, state='not_quarantined',
            })
    end
    if request.run_id ~= registry.quarantine.run_id or
            request.generation ~= registry.quarantine.generation then
        validation.reject('quarantine_mismatch',
            'The requested generation does not own executor quarantine.', {
                operation='recover executor', run_id=request.run_id,
                generation=request.generation,
                blocking_run_id=registry.quarantine.run_id,
                blocking_generation=registry.quarantine.generation,
            })
    end
    assert(type(request.reason) == 'string' and request.reason ~= '' and
        #request.reason <= 1024,
        'executor recovery reason must be a nonempty bounded string')
    assert(type(request.proof) == 'table',
        'executor recovery requires a clean-state proof')
    events.copy_json(request.proof, 'executor recovery proof')
    assert(type(context.verify_clean_state) == 'function',
        'executor recovery requires an authoritative verifier')
    local verified, detail = context.verify_clean_state(request.proof)
    if verified ~= true then
        validation.reject('clean_state_unverified',
            'Executor clean state could not be verified.', {
                operation='recover executor', run_id=request.run_id,
                generation=request.generation,
                reason=validation.safe_reason(detail,
                    'clean-state proof was rejected'),
            })
    end
    transitions.clear_quarantine(registry)
    return {recovered=true}
end

---Acknowledges one exact owner-retained terminal result after persistence.
function M.acknowledge(registry, request, context)
    local run = validation.authorize_owner(registry, request, 'acknowledgement')
    if not run.terminal or not TERMINAL[run.state] then
        validation.reject('invalid_run_state',
            'Only a terminal run can be acknowledged.', {
                operation='acknowledgement', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
    if run.acknowledged == true or run.discarded == true then
        validation.reject('invalid_run_state',
            'The terminal run has already been released.', {
                operation='acknowledgement', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
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
    if not run.terminal or not TERMINAL[run.state] then
        validation.reject('invalid_run_state',
            'Only a terminal run can be discarded.', {
                operation='discard', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
    if run.acknowledged == true or run.discarded == true then
        validation.reject('invalid_run_state',
            'The terminal run has already been released.', {
                operation='discard', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
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
    if registry.active_run_id ~= run.run_id or not ACTIVE[run.state] or
            run.terminal then
        validation.reject('invalid_run_state',
            'Only the active run can be force-aborted.', {
                operation='operator abort', run_id=run.run_id,
                generation=run.generation, state=run.state,
            })
    end
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
