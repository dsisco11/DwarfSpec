-- Unit characterization of the legacy bootstrap and abort entrypoint protocol.

describe('legacy automation entrypoint contract', function()
    local original_dfhack
    local original_print
    local original_package_path
    local original_json_loader
    local original_json_module
    local callbacks
    local active_callbacks
    local lines
    local encoded
    local tick

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_print = rawget(_G, 'print')
        original_package_path = package.path
        original_json_loader = package.preload.json
        original_json_module = package.loaded.json
        callbacks = {}
        active_callbacks = {}
        lines = {}
        encoded = {}
        tick = 0

        rawset(_G, 'dfhack', {
            is_core_context=true,
            filesystem={
                getcwd=function()
                    return 'default-project'
                end,
            },
        })
        rawset(_G, 'print', function(line)
            table.insert(lines, line)
        end)
        package.preload.json = function()
            return {
                encode=function(value)
                    table.insert(encoded, value)
                    return '{"legacy":true}'
                end,
            }
        end
        package.loaded.json = nil

        ---Returns one deterministic legacy host timestamp.
        ---@return integer
        function dfhack.getTickCount()
            tick = tick + 1
            return tick
        end

        ---Captures one legacy frame callback without executing it.
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

        ---Returns and replaces one legacy timeout registration.
        ---@param id integer
        ---@param replacement function|nil
        ---@return function|nil
        function dfhack.timeout_active(id, replacement)
            local callback = active_callbacks[id]
            active_callbacks[id] = replacement
            return callback
        end
    end)

    after_each(function()
        package.path = original_package_path
        package.preload.json = original_json_loader
        package.loaded.json = original_json_module
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'print', original_print)
    end)

    it('starts and aborts through version 1 text and JSON entrypoints',
            function()
        local root = require('lfs').currentdir()
        assert(loadfile(root ..
            '/tests/automation/support/bootstrap.lua'))(
            'entrypoint-contract',
            '--project-root=tests/framework/service project beta',
            '--repeat=2',
            '--defer-frames=3',
            '--lease-timeout-ms=9000',
            '--lease-check-frames=4',
            '--test-glob=tests/live/*.ds.lua',
            '--spec=live/shared_spec.ds.lua')

        local registry = dfhack.dwarfspec
        local run = registry.runs['entrypoint-contract']
        assert.equals(2, registry.protocol_version)
        assert.equals(1, registry.generation)
        assert.equals(run.run_id, registry.active_run_id)
        assert.equals('starting', run.state)
        assert.equals(2, run.options.repeat_count)
        assert.equals(3, run.options.defer_frames)
        assert.equals(9000, run.options.lease_timeout_ms)
        assert.equals(4, run.options.lease_check_frames)
        assert.equals('tests/live/*.ds.lua', run.options.test_glob)
        assert.same({'live/shared_spec.ds.lua'}, run.options.specs)
        assert.matches('DWARFSPEC protocol=1 ' ..
            'run_id=entrypoint-contract state=starting generation=1',
            lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[2])
        assert.equals('dwarfspec.run.v1', encoded[1].schema)
        assert.equals(1, encoded[1].protocol)

        lines = {}
        assert(loadfile(root .. '/tests/automation/support/abort.lua'))(
            'entrypoint-contract')

        assert.is_nil(registry.active_run_id)
        assert.equals(run.run_id,
            registry.latest_terminal_results[run.project_id])
        assert.equals('aborted', run.state)
        assert.is_true(run.cleanup_confirmed)
        assert.is_true(run.terminal_observed)
        assert.matches('DWARFSPEC protocol=1 ' ..
            'run_id=entrypoint-contract state=aborted generation=1',
            lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[2])
        assert.equals('dwarfspec.run.v1', encoded[2].schema)
        assert.equals(1, encoded[2].protocol)
    end)
end)
