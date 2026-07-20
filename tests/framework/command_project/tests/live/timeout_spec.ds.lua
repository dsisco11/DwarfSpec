-- Deliberate long frame wait used to prove external timeout recovery.

describe('command runner timeout path', function()
    it('remains suspended until the external runner aborts it', function()
        ds.wait_until('deliberate external timeout', function()
            return false
        end, {frame_budget=100000, timeout_ms=60000})
    end)
end)
