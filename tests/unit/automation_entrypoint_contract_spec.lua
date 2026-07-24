-- Unit contract for version 2 bootstrap, recovery, and acknowledgement.

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

    it('reports an unloaded service without creating a registry', function()
        local root = require('lfs').currentdir()

        assert(loadfile(root ..
            '/tests/automation/support/scheduler_status.lua'))()

        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[1])
        assert.equals('dwarfspec.status.v1', encoded[1].schema)
        assert.is_false(encoded[1].service_loaded)
        assert.is_nil(encoded[1].scheduler)
        assert.is_nil(dfhack.dwarfspec)
    end)

    it('starts and aborts through version 2 transport entrypoints',
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
        assert.matches('DWARFSPEC protocol=2 ' ..
            'run_id=entrypoint-contract state=queued generation=1',
            lines[1], 1, true)
        assert.matches('DWARFSPEC_OWNER owner-', lines[2], 1, true)
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[3])
        assert.equals('dwarfspec.transport.v2', encoded[1].schema)
        assert.equals(2, encoded[1].protocol)

        lines = {}
        assert(loadfile(root .. '/tests/automation/support/abort.lua'))(
            'entrypoint-contract', run.owner_capability)

        assert.is_nil(registry.active_run_id)
        assert.equals(run.run_id,
            registry.latest_terminal_results[run.project_id])
        assert.equals('aborted', run.state)
        assert.is_true(run.cleanup_confirmed)
        assert.is_false(run.terminal_observed)
        assert.equals(run.run_id,
            registry.projects[run.project_id].outstanding_run_id)
        assert.matches('DWARFSPEC protocol=2 ' ..
            'run_id=entrypoint-contract state=aborted generation=1',
            lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[2])
        assert.equals('dwarfspec.transport.v2', encoded[2].schema)
        assert.equals(2, encoded[2].protocol)

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/acknowledge.lua'))(
            'entrypoint-contract', tostring(run.generation),
            run.owner_capability, tostring(#run.event_journal.events))
        assert.is_true(run.acknowledged)
        assert.is_nil(registry.projects[run.project_id].outstanding_run_id)
        assert.matches('acknowledged=true', lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[2])
        assert.equals('dwarfspec.transport.v2', encoded[3].schema)

        registry.package_version = '0.1.3'
        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/bootstrap.lua'))(
            'entrypoint-version-rejection')
        assert.same({'DWARFSPEC_JSON {"legacy":true}'}, lines)
        assert.equals('dwarfspec.error.v1', encoded[4].schema)
        assert.equals(2, encoded[4].protocol)
        assert.equals('registration', encoded[4].kind)
        assert.matches('incompatible automation package version: ' ..
            'expected 0.1.3, found 0.2.0', encoded[4].message, 1, true)
        assert.is_nil(registry.runs['entrypoint-version-rejection'])

        registry.package_version = '0.2.0'
        registry.quarantine = {
            active=true,
            run_id=run.run_id,
            generation=run.generation,
            reason='cleanup was not confirmed',
        }
        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/bootstrap.lua'))(
            'entrypoint-quarantine-rejection')
        assert.same({'DWARFSPEC_JSON {"legacy":true}'}, lines)
        assert.equals('dwarfspec.error.v1', encoded[5].schema)
        assert.equals('executor_quarantined', encoded[5].kind)
        assert.equals(run.run_id, encoded[5].blocking_run_id)
        assert.equals(run.generation, encoded[5].blocking_generation)
        assert.matches('recover-executor ' .. run.run_id ..
            ' --generation ' .. run.generation, encoded[5].message, 1, true)
        assert.is_nil(registry.runs['entrypoint-quarantine-rejection'])
    end)

    it('keeps cancel, event, scheduler, recovery, and discard adapters thin',
            function()
        local root = require('lfs').currentdir()
        local host = assert(loadfile(root ..
            '/src/dwarfspec/automation/host.lua'))()
        local queued = host.start(root,
            'tests/framework/service project beta', {
                run_id='adapter-cancel',
                defer_activation=true,
                defer_frames=1,
                lease_timeout_ms=9000,
                lease_check_frames=4,
            })

        assert(loadfile(root .. '/tests/automation/support/cancel.lua'))(
            queued.run_id, queued.owner_capability, '0', 'fixture cancel')
        assert.equals('cancelled', queued.state)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)
        assert.equals('cancelled', encoded[#encoded].snapshot.state)

        lines = {}
        assert(loadfile(root .. '/tests/automation/support/events.lua'))(
            queued.run_id, tostring(encoded[#encoded].last_sequence))
        assert.equals(1, #lines)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)
        assert.same({}, encoded[#encoded].events)

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/scheduler_status.lua'))(
            queued.run_id, tostring(encoded[#encoded].last_sequence))
        assert.equals('dwarfspec.scheduler.v2',
            encoded[#encoded].scheduler.schema)
        local query_cursor = encoded[#encoded].last_sequence

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/run_query.lua'))('history')
        assert.equals('dwarfspec.history.v1', encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].service_loaded)
        assert.equals(1, #encoded[#encoded].runs)
        assert.equals(queued.run_id, encoded[#encoded].runs[1].run_id)

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/run_query.lua'))(
            'show', queued.run_id)
        assert.equals('dwarfspec.run-inspection.v1',
            encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].found)
        assert.equals(queued.run_id, encoded[#encoded].snapshot.run_id)

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/run_query.lua'))(
            'logs', queued.run_id)
        assert.equals('dwarfspec.run-logs.v1', encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].found)
        assert.same({'CANCELLED fixture cancel'},
            encoded[#encoded].lines)
        encoded[#encoded].lines[1] = 'mutated query result'
        assert.same({'CANCELLED fixture cancel'}, queued.output_lines)

        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/run_query.lua'))(
            'show', 'missing-run')
        assert.is_false(encoded[#encoded].found)
        assert.is_nil(encoded[#encoded].snapshot)

        lines = {}
        assert(loadfile(root .. '/tests/automation/support/discard.lua'))(
            queued.run_id, tostring(queued.generation),
            tostring(query_cursor), 'fixture discard')
        assert.is_true(queued.discarded)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)

        local active = host.start(root,
            'tests/framework/minimal_project', {
                run_id='adapter-recover',
                defer_frames=1,
                lease_timeout_ms=9000,
                lease_check_frames=4,
            })
        local cursor = #active.event_journal.events
        lines = {}
        assert(loadfile(root .. '/tests/automation/support/recover.lua'))(
            active.run_id, active.owner_capability, tostring(cursor),
            'fixture recovery')
        assert.equals('aborted', active.state)
        assert.is_true(active.cleanup_confirmed)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)

        dfhack.dwarfspec.quarantine = {active=false}
        lines = {}
        assert(loadfile(root ..
            '/tests/automation/support/scheduler_status.lua'))()
        assert.equals('DWARFSPEC_JSON {"legacy":true}', lines[1])
        assert.equals('dwarfspec.status.v1',
            encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].service_loaded)
        assert.equals('dwarfspec.scheduler.v2',
            encoded[#encoded].scheduler.schema)
    end)
end)
