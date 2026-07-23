-- Unit contracts for the cursor-based status transport adapter.

describe('automation status formatting', function()
    local original_dfhack
    local original_print
    local original_json_loader
    local original_json_module
    local callbacks
    local active_callbacks
    local lines
    local tick
    local host

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_print = rawget(_G, 'print')
        original_json_loader = package.preload.json
        original_json_module = package.loaded.json
        callbacks = {}
        active_callbacks = {}
        lines = {}
        tick = 0
        rawset(_G, 'dfhack', {is_core_context=true})
        rawset(_G, 'print', function(line)
            table.insert(lines, line)
        end)
        package.preload.json = function()
            return {
                encode=function()
                    return '{"native":true}'
                end,
            }
        end
        package.loaded.json = nil

        ---Returns a deterministic status timestamp.
        ---@return integer
        function dfhack.getTickCount()
            tick = tick + 1
            return tick
        end

        ---Captures one scheduled fake timeout.
        ---@param delay integer
        ---@param mode string
        ---@param callback function
        ---@return integer
        function dfhack.timeout(delay, mode, callback)
            assert.equals('frames', mode)
            local id = #callbacks + 1
            callbacks[id] = callback
            active_callbacks[id] = callback
            return id
        end

        ---Returns and updates one fake timeout registration.
        ---@param id integer
        ---@param callback function|nil
        ---@return function|nil
        function dfhack.timeout_active(id, callback)
            local previous = active_callbacks[id]
            active_callbacks[id] = callback
            return previous
        end

        host = assert(loadfile(
            'src/dwarfspec/automation/host.lua'))()
    end)

    after_each(function()
        package.preload.json = original_json_loader
        package.loaded.json = original_json_module
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'print', original_print)
    end)

    ---Returns the smallest valid host-run options for status formatting.
    ---@return table
    local function options()
        return {
            run_id='status-run',
            defer_frames=1,
            lease_timeout_ms=1000,
            lease_check_frames=1,
        }
    end

    it('emits diagnostics and one canonical version 2 transport response',
            function()
        local run = host.start('.', '.', options())
        run.output_lines = {'line one\nline two'}

        assert(loadfile('./tests/automation/support/status.lua'))('status-run',
            run.owner_capability, '0')

        assert.matches('DWARFSPEC protocol=2 run_id=status-run ' ..
            'state=starting generation=1', lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"native":true}', lines[2])
        assert.equals(run, host.find('status-run'))
        host.abort('status-run', run.owner_capability)
    end)
end)
