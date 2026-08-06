-- Deterministic fake-clock contracts for command deadlines.

local Deadline = require('dwarfspec.driver.command.deadline')

describe('command deadline', function()
    it('samples once at construction and never resets its absolute deadline',
            function()
        local now = 100.25
        local samples = 0
        local deadline = Deadline.new(function()
            samples = samples + 1
            return now
        end, 10)
        assert.equals(1, samples)
        assert.equals(110.25, deadline:expires_at_ms())
        now = 103.5
        assert.equals(7, deadline:remaining_ms())
        assert.equals(110.25, deadline:expires_at_ms())
    end)

    it('rounds positive fractional remaining time upward', function()
        local now = 0
        local deadline = Deadline.new(function() return now end, 5)
        now = 4.01
        assert.equals(1, deadline:remaining_ms())
        assert.is_false(deadline:is_expired())
        now = 5
        assert.equals(0, deadline:remaining_ms())
        assert.is_true(deadline:is_expired())
    end)

    it('reports late synchronous return with preserved evidence', function()
        local now = 10
        local deadline = Deadline.new(function() return now end, 3)
        local evidence = {adapter='native', acknowledgement=false}
        now = 14
        local completed, timeout = deadline:check_execution_return(evidence)
        assert.is_false(completed)
        assert.equals('timeout', timeout.kind)
        assert.equals('execution', timeout.failure_stage)
        assert.equals(13, timeout.deadline_ms)
        assert.equals(14, timeout.returned_at_ms)
        assert.equals(evidence, timeout.evidence)
    end)

    it('rejects invalid clocks and unbounded timeout values', function()
        assert.has_error(function() Deadline.new(nil, 10) end)
        for _, timeout in ipairs({0, -1, 1.5, math.huge}) do
            assert.has_error(function()
                Deadline.new(function() return 0 end, timeout)
            end)
        end
        assert.has_error(function()
            Deadline.new(function() return 0 / 0 end, 10)
        end)
    end)
end)
