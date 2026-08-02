-- Shared deterministic fixtures for direct scheduler policy tests.

local service = require('dwarfspec.host.service.service')
local OwnerKind = require('dwarfspec.protocol.enums.owner_kinds')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')

local M = {}

---Creates a bootstrapped service registry and deterministic dependencies.
function M.environment()
    local namespace, now, capability, next_timer_id = {}, 100, 0, 0
    local controls = {
        timers={},
        cancelled_timers={},
        authorization_operations={},
        activation_rejection=nil,
        expiry_calls=0,
    }
    local dependencies = {
        namespace=namespace,
        now_ms=function() return now end,
        new_service_instance_id=function() return 'direct-scheduler-service' end,
        new_run_id=function(generation) return 'direct-run-' .. generation end,
        new_owner_capability=function()
            capability = capability + 1
            return ('direct-owner-capability-%020d'):format(capability)
        end,
        validate_activation=function()
            if controls.activation_rejection then
                return false, controls.activation_rejection
            end
            return true
        end,
        authorize_operator=function(authority, operation)
            table.insert(controls.authorization_operations, operation)
            return authority.allowed == true, 'direct operator'
        end,
        verify_clean_state=function(proof)
            return proof.clean == true, 'clean-state proof rejected'
        end,
        schedule_lease_timer=function(_, delay_ms, callback)
            next_timer_id = next_timer_id + 1
            controls.timers[next_timer_id] = {
                delay_ms=delay_ms,
                callback=callback,
            }
            return next_timer_id
        end,
        cancel_lease_timer=function(timer_id)
            table.insert(controls.cancelled_timers, timer_id)
        end,
    }
    service.bootstrap({protocol_version=2, package_root='.',
        package_version='0.2.1'}, dependencies)
    controls.set_time = function(value) now = value end
    controls.registry = namespace.dwarfspec
    dependencies.expire_leases = function()
        controls.expiry_calls = controls.expiry_calls + 1
    end
    return dependencies, controls
end

---Registers one project suitable for direct scheduler tests.
function M.project(dependencies, suffix, overrides)
    local request = {
        project_root='tests/framework/minimal_project',
        display_name='Direct Scheduler ' .. suffix,
        normalized_configuration={suffix=suffix},
        result_policy=ResultPolicy.NONE,
        client_compatibility={protocol=2, package_version='0.2.1'},
    }
    for key, value in pairs(overrides or {}) do request[key] = value end
    return service.register_project(request, dependencies)
end

---Returns one valid external submission request.
function M.submission(suffix)
    return {request_key='direct-request-' .. suffix .. '-0001',
        owner_kind=OwnerKind.EXTERNAL,
        selection={identities={'tests/live/example.ds.lua'}}}
end

---Returns an exact owner request for an admitted run.
function M.owner_request(admitted, extra)
    local request = {service_instance_id=admitted.identity.service_instance_id,
        project_id=admitted.identity.project_id,
        run_id=admitted.identity.run_id,
        generation=admitted.identity.generation,
        owner_capability=admitted.owner_capability}
    for key, value in pairs(extra or {}) do request[key] = value end
    return request
end

return M
