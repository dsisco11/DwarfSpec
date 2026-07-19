-- Unit contracts for live automation ownership and generation guards.

local host_path = 'Tests/Automation/support/busted_host.lua'

describe('automation host ownership', function()
    local original_dfhack
    local callbacks
    local active_callbacks
    local tick
    local host

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        callbacks = {}
        active_callbacks = {}
        tick = 0
        rawset(_G, 'dfhack', {
            is_core_context=true,
            dwarfui={},
        })

        ---Returns a deterministic monotonic unit-test tick.
        ---@return integer
        function dfhack.getTickCount()
            tick = tick + 1
            return tick
        end

        ---Captures one fake frame callback without executing it.
        ---@param delay integer
        ---@param mode string
        ---@param callback function
        ---@return integer
        function dfhack.timeout(delay, mode, callback)
            assert.equals('frames', mode)
            assert.is_true(delay >= 1)
            local id = #callbacks + 1
            callbacks[id] = callback
            active_callbacks[id] = callback
            return id
        end

        ---Returns, replaces, or cancels an active fake callback.
        ---@param id integer
        ---@param replacement function|nil
        ---@return function|nil
        function dfhack.timeout_active(id, replacement)
            local callback = active_callbacks[id]
            active_callbacks[id] = replacement
            return callback
        end

        host = assert(loadfile(host_path))()
    end)

    after_each(function()
        rawset(_G, 'dfhack', original_dfhack)
    end)

    ---Returns the smallest valid queued-run option set.
    ---@param run_id string
    ---@return table
    local function options(run_id)
        return {
            run_id=run_id,
            filters={},
            filter_out={},
            names={},
            tags={},
            exclude_tags={},
            repeat_count=1,
            seed=1,
            spec=nil,
            defer_frames=1,
        }
    end

    it('rejects overlap and ignores a callback after abort', function()
        local run = host.start('unused', options('owner'))
        assert.equals('starting', run.state)
        assert.has_error(function()
            host.start('unused', options('overlap'))
        end, 'automation run owner is already starting')

        local aborted = host.abort('owner')
        assert.equals('aborted', aborted.state)
        assert.is_nil(active_callbacks[1])
        callbacks[1]()
        assert.equals('aborted', aborted.state)
        assert.equals(aborted, host.find('owner'))
    end)

    it('retains an unobserved result until its owner acknowledges it', function()
        local aborted = host.abort(host.start(
            'unused', options('retained')).run_id)
        assert.has_error(function()
            host.start('unused', options('replacement'))
        end, 'automation run retained has an unobserved aborted result')

        aborted.terminal_observed = true
        local replacement = host.start('unused', options('replacement'))
        assert.equals('starting', replacement.state)
        host.abort(replacement.run_id)
    end)
end)
