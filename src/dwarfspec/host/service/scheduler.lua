-- Public scheduler facade for the automation service.

local admission = require('dwarfspec.host.service.scheduler.admission')
local leases = require('dwarfspec.host.service.scheduler.leases')
local queue = require('dwarfspec.host.service.scheduler.queue')
local recovery = require('dwarfspec.host.service.scheduler.recovery')
local transitions = require('dwarfspec.host.service.scheduler.transitions')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')

local M = {failure_kinds=SchedulerFailureKind}

---Admits one run to the global FIFO.
function M.submit(...) return admission.submit(...) end
---Activates the next eligible FIFO run.
function M.activate_next(...) return queue.activate_next(...) end
---Moves an active run into running state.
function M.start_active(...) return transitions.start_active(...) end
---Moves an active run into cleanup state.
function M.begin_cleanup(...) return transitions.begin_cleanup(...) end
---Publishes a generation-guarded event for an active run.
function M.publish_active_event(...) return transitions.publish_active_event(...) end
---Cancels an owner-authorized queued run.
function M.cancel(...) return queue.cancel(...) end
---Cancels an operator-authorized queued run.
function M.operator_cancel(...) return queue.operator_cancel(...) end
---Expires all due external queue leases.
function M.expire_due_queue(...) return queue.expire_due_queue(...) end
---Renews the applicable external lease.
function M.renew(...) return leases.renew(...) end
---Renews an in-process execution heartbeat.
function M.heartbeat(...) return leases.heartbeat(...) end
---Claims an expired external active lease.
function M.claim_expired_active(...) return leases.claim_expired_active(...) end
---Arms or replaces the timer for one renewable lease.
function M.arm_lease_timer(...) return leases.arm_timer(...) end
---Cancels and invalidates one renewable lease timer.
function M.cancel_lease_timer(...) return leases.cancel_timer(...) end
---Authorizes an owner-requested active abort.
function M.authorize_abort(...) return recovery.authorize_abort(...) end
---Finishes and releases an active executor generation.
function M.finish_active(...) return transitions.finish_active(...) end
---Clears executor quarantine after clean-state verification.
function M.recover_executor(...) return recovery.recover_executor(...) end
---Acknowledges a retained terminal result.
function M.acknowledge(...) return recovery.acknowledge(...) end
---Discards a retained terminal result through operator authority.
function M.discard(...) return recovery.discard(...) end
---Authorizes an operator-requested active abort.
function M.authorize_operator_abort(...) return recovery.authorize_operator_abort(...) end

return M
