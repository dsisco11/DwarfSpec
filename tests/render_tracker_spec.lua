-- Unit contracts for private render completion tracking.

local render_tracker = assert(loadfile(
    'src/dwarfspec/render_tracker.lua'))()

---Creates a scheduler adapter that evaluates waits synchronously.
---@return table
local function immediate_scheduler()
    return {
        wait_until=function(_, description, query)
            local result = query()
            assert(result, 'wait did not complete: ' .. description)
            return result
        end,
    }
end

describe('DwarfSpec render tracker', function()
    it('advances only after successful completed renders', function()
        local tracker = render_tracker.new(immediate_scheduler(), {})
        local captured = tracker:capture()

        assert.equals(0, captured)
        assert.equals(1, tracker:completed())
        assert.equals(1, tracker:wait_after(captured))
        assert.equals(1, tracker:generation())
    end)

    it('retains failures without advancing its generation', function()
        local tracker = render_tracker.new(immediate_scheduler(), {})
        local captured = tracker:capture()

        tracker:failed('render exploded')

        assert.equals(0, tracker:generation())
        assert.has_error(function()
            tracker:wait_after(captured)
        end, 'render exploded')
    end)

    it('clears an observed failure when a new operation is captured', function()
        local tracker = render_tracker.new(immediate_scheduler(), {})
        tracker:failed('stale failure')

        local captured = tracker:capture()
        tracker:completed()

        assert.equals(1, tracker:wait_after(captured))
    end)
end)
