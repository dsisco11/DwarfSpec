-- Unit contract for version 2 bootstrap, recovery, and acknowledgement.

local layout = require('dwarfspec.layout')

---Loads one direct DFHack entrypoint through the package layout authority.
---@param name string
---@return function
local function load_host_script(name)
    return assert(loadfile(layout.current().host_scripts[name]))
end

describe('version 2 automation entrypoint contract', function()
    local original_dfhack
    local original_print
    local original_package_path
    local original_json_loader
    local original_json_module
    local callbacks
    local active_callbacks
    local lines
    local encoded
    local encode_options
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
        encode_options = {}
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
                encode=function(value, options)
                    table.insert(encoded, value)
                    table.insert(encode_options, options or {})
                    return '{"encoded":true}'
                end,
            }
        end
        package.loaded.json = nil

        ---Returns one deterministic host timestamp.
        ---@return integer
        function dfhack.getTickCount()
            tick = tick + 1
            return tick
        end

        ---Captures one frame callback without executing it.
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

        ---Returns and replaces one timeout registration.
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

        load_host_script('scheduler_status')()

        assert.equals('DWARFSPEC_JSON {"encoded":true}', lines[1])
        assert.equals('dwarfspec.status.v1', encoded[1].schema)
        assert.is_false(encode_options[1].pretty)
        assert.is_false(encoded[1].service_loaded)
        assert.is_nil(encoded[1].scheduler)
        assert.is_nil(dfhack.dwarfspec)
    end)

    it('emits one structured rejection from every unloaded mutation adapter',
            function()
        local cases = {
            {name='abort', arguments={'missing-run', ''}},
            {name='cancel', arguments={'missing-run', 'owner-secret', '0'}},
            {name='recover', arguments={'missing-run', 'owner-secret', '0'}},
            {name='acknowledge', arguments={
                'missing-run', '1', 'owner-secret', '0'}},
            {name='discard', arguments={'missing-run', '1', '0'}},
            {name='recover_executor', arguments={'missing-run', '1', '0'}},
        }
        for _, case in ipairs(cases) do
            lines = {}
            load_host_script(case.name)(table.unpack(case.arguments))
            assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines, case.name)
            local rejection = encoded[#encoded]
            assert.equals('dwarfspec.error.v1', rejection.schema)
            assert.equals('host', rejection.kind)
            assert.equals('service_not_loaded', rejection.code)
            assert.is_nil(rejection.owner_capability)
            assert.is_nil(rejection.authorization_proof)
            assert.is_falsy(rejection.message:find('owner-secret', 1, true))
        end
        assert.is_nil(dfhack.dwarfspec)
    end)

    it('serializes polling and event rejections with one safe response',
            function()
        for _, case in ipairs({
            {name='status', arguments={'missing-run', 'owner-secret', '0', '1'}},
            {name='event_read', arguments={'missing-run', '0', '1'}},
            {name='scheduler_status', arguments={'missing-run', '0', '1'}},
        }) do
            lines = {}
            load_host_script(case.name)(table.unpack(case.arguments))
            assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
            assert.equals('service_not_loaded', encoded[#encoded].code)
            assert.is_falsy(encoded[#encoded].message:find(
                'owner-secret', 1, true))
        end

        local root = require('lfs').currentdir():gsub('\\', '/')
        lines = {}
        load_host_script('bootstrap')('poll-entrypoint',
            '--project-root=' .. root, '--defer-frames=1')
        local run = assert(dfhack.dwarfspec.runs['poll-entrypoint'])
        local last_sequence = #run.event_journal.events
        local cases = {
            {name='status', arguments={run.run_id, run.owner_capability,
                '0', tostring(run.generation + 1)},
                code='generation_mismatch'},
            {name='status', arguments={run.run_id, 'owner-secret', '0',
                tostring(run.generation)}, code='owner_capability_rejected'},
            {name='event_read', arguments={run.run_id,
                tostring(last_sequence + 1), tostring(run.generation)},
                code='event_cursor_ahead'},
            {name='event_read', arguments={'missing-run', '0', '1'},
                code='run_not_found'},
            {name='scheduler_status', arguments={run.run_id, '0',
                tostring(run.generation + 1)}, code='generation_mismatch'},
        }
        for _, case in ipairs(cases) do
            lines = {}
            load_host_script(case.name)(table.unpack(case.arguments))
            assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines, case.name)
            local rejection = encoded[#encoded]
            assert.equals('dwarfspec.error.v1', rejection.schema)
            assert.equals(case.code, rejection.code)
            assert.is_nil(rejection.owner_capability)
            assert.is_nil(rejection.authorization_proof)
            assert.is_falsy(rejection.message:find('owner-secret', 1, true))
        end
    end)

    it('keeps unexpected adapter faults on the subprocess failure path',
            function()
        local response =
            require('dwarfspec.host.entrypoints.operation_response')
        local ok, detail = pcall(response.execute,
            function() error('unexpected invariant failure', 0) end,
            function() error('success must not be emitted') end,
            require('json').encode)
        assert.is_false(ok)
        assert.equals('unexpected invariant failure', detail)
        assert.same({}, lines)
        assert.same({}, encoded)
    end)

    it('preserves generic string bootstrap rejections', function()
        load_host_script('bootstrap')(
            'entrypoint-generic-rejection', '--unknown=value')

        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.equals('dwarfspec.error.v1', encoded[1].schema)
        assert.equals(2, encoded[1].protocol)
        assert.equals('registration', encoded[1].kind)
        assert.matches('unknown automation option: --unknown',
            encoded[1].message, 1, true)
        assert.is_nil(encoded[1].code)
        assert.is_nil(encoded[1].running_version)
        assert.is_nil(encoded[1].requested_version)
        assert.is_false(encode_options[1].pretty)
        assert.is_nil(dfhack.dwarfspec)
    end)

    it('serializes admission conflicts with exact safe blocking fields',
            function()
        local root = require('lfs').currentdir():gsub('\\', '/')
        local result_path = root .. '/shared-result.json'
        load_host_script('bootstrap')(
            'admission-owner', '--project-root=.', '--result-policy=file',
            '--result-path=' .. result_path)
        local registry = dfhack.dwarfspec
        local owner = registry.runs['admission-owner']

        lines = {}
        load_host_script('bootstrap')(
            'admission-owner', '--project-root=.', '--result-policy=file',
            '--result-path=' .. result_path)
        assert.equals('dwarfspec.transport.v2', encoded[2].schema)
        assert.matches('DWARFSPEC_OWNER ', lines[2], 1, true)
        assert.equals(1, registry.generation)

        lines = {}
        load_host_script('bootstrap')(
            'admission-owner', '--project-root=.', '--result-policy=file',
            '--result-path=' .. result_path, '--spec=different.ds.lua')
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.same({
            schema='dwarfspec.error.v1',
            protocol=2,
            kind='registration',
            code='request_key_conflict',
            message='This request identity is already bound to a different ' ..
                'DwarfSpec run.',
            blocking_run_id=owner.run_id,
            blocking_generation=owner.generation,
            state=owner.state,
            reason='request key is already bound to a different request',
        }, encoded[3])

        lines = {}
        load_host_script('bootstrap')(
            'admission-project-busy', '--project-root=.',
            '--result-policy=file', '--result-path=' .. result_path)
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.equals('project_busy', encoded[4].code)
        assert.equals('registration', encoded[4].kind)
        assert.equals(owner.run_id, encoded[4].blocking_run_id)
        assert.equals(owner.generation, encoded[4].blocking_generation)
        assert.equals(owner.state, encoded[4].state)
        assert.equals('project already owns an outstanding run',
            encoded[4].reason)
        assert.is_string(encoded[4].message)
        assert.is_true(encoded[4].message ~= '')

        lines = {}
        load_host_script('bootstrap')(
            'admission-result-busy', '--project-root=tests',
            '--result-policy=file', '--result-path=' .. result_path)
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.equals('result_path_busy', encoded[5].code)
        assert.equals('registration', encoded[5].kind)
        assert.equals(owner.run_id, encoded[5].blocking_run_id)
        assert.equals(owner.generation, encoded[5].blocking_generation)
        assert.equals(owner.state, encoded[5].state)
        assert.equals('result path is owned by another outstanding run',
            encoded[5].reason)
        assert.is_nil(encoded[5].project_root)
        assert.is_nil(encoded[5].result_path)
        assert.is_nil(encoded[5].owner_capability)
        assert.equals(1, registry.generation)
        assert.is_nil(registry.runs['admission-project-busy'])
        assert.is_nil(registry.runs['admission-result-busy'])
    end)

    it('starts and aborts through version 2 transport entrypoints',
            function()
        local root = require('lfs').currentdir()
        load_host_script('bootstrap')(
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
        assert.equals('DWARFSPEC_JSON {"encoded":true}', lines[3])
        assert.equals('dwarfspec.transport.v2', encoded[1].schema)
        assert.equals(2, encoded[1].protocol)

        lines = {}
        load_host_script('abort')(
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
        assert.equals('DWARFSPEC_JSON {"encoded":true}', lines[2])
        assert.equals('dwarfspec.transport.v2', encoded[2].schema)
        assert.equals(2, encoded[2].protocol)

        lines = {}
        load_host_script('acknowledge')(
            'entrypoint-contract', tostring(run.generation),
            run.owner_capability, tostring(#run.event_journal.events))
        assert.is_true(run.acknowledged)
        assert.is_nil(registry.projects[run.project_id].outstanding_run_id)
        assert.matches('acknowledged=true', lines[1], 1, true)
        assert.equals('DWARFSPEC_JSON {"encoded":true}', lines[2])
        assert.equals('dwarfspec.transport.v2', encoded[3].schema)

        registry.package_version = '0.1.3'
        lines = {}
        load_host_script('bootstrap')(
            'entrypoint-version-rejection')
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.equals('dwarfspec.error.v1', encoded[4].schema)
        assert.equals(2, encoded[4].protocol)
        assert.equals('registration', encoded[4].kind)
        assert.equals('package_version_mismatch', encoded[4].code)
        assert.equals('0.1.3', encoded[4].running_version)
        assert.equals('0.2.2', encoded[4].requested_version)
        assert.is_string(encoded[4].message)
        assert.is_true(encoded[4].message ~= '')
        assert.is_false(encode_options[4].pretty)
        assert.matches('DFHack already has a different DwarfSpec version ' ..
            'loaded', encoded[4].message, 1, true)
        assert.is_nil(encoded[4].package_root)
        assert.is_nil(registry.runs['entrypoint-version-rejection'])

        registry.package_version = '0.2.2'
        registry.quarantine = {
            active=true,
            run_id=run.run_id,
            generation=run.generation,
            reason='cleanup was not confirmed',
        }
        lines = {}
        load_host_script('bootstrap')(
            'entrypoint-quarantine-rejection')
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
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
            '/src/dwarfspec/host/execution/host.lua'))()
        local queued = host.start(root,
            'tests/framework/service project beta', {
                run_id='adapter-cancel',
                defer_activation=true,
                defer_frames=1,
                lease_timeout_ms=9000,
                lease_check_frames=4,
            })

        load_host_script('cancel')(
            queued.run_id, queued.owner_capability, '0', 'fixture cancel')
        assert.equals('cancelled', queued.state)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)
        assert.equals('cancelled', encoded[#encoded].snapshot.state)

        lines = {}
        load_host_script('event_read')(
            queued.run_id, tostring(encoded[#encoded].last_sequence))
        assert.equals(1, #lines)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)
        assert.same({}, encoded[#encoded].events)

        lines = {}
        load_host_script('scheduler_status')(
            queued.run_id, tostring(encoded[#encoded].last_sequence))
        assert.equals('dwarfspec.scheduler.v2',
            encoded[#encoded].scheduler.schema)
        local query_cursor = encoded[#encoded].last_sequence

        lines = {}
        load_host_script('run_query')('history')
        assert.equals('dwarfspec.history.v1', encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].service_loaded)
        assert.equals(1, #encoded[#encoded].runs)
        assert.equals(queued.run_id, encoded[#encoded].runs[1].run_id)

        lines = {}
        load_host_script('run_query')(
            'show', queued.run_id)
        assert.equals('dwarfspec.run-inspection.v1',
            encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].found)
        assert.equals(queued.run_id, encoded[#encoded].snapshot.run_id)

        lines = {}
        load_host_script('run_query')(
            'logs', queued.run_id)
        assert.equals('dwarfspec.run-logs.v1', encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].found)
        assert.same({'CANCELLED fixture cancel'},
            encoded[#encoded].lines)
        encoded[#encoded].lines[1] = 'mutated query result'
        assert.same({'CANCELLED fixture cancel'}, queued.output_lines)

        lines = {}
        load_host_script('run_query')(
            'show', 'missing-run')
        assert.is_false(encoded[#encoded].found)
        assert.is_nil(encoded[#encoded].snapshot)

        lines = {}
        load_host_script('discard')(
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
        load_host_script('recover')(
            active.run_id, active.owner_capability, tostring(cursor),
            'fixture recovery')
        assert.equals('aborted', active.state)
        assert.is_true(active.cleanup_confirmed)
        assert.equals('dwarfspec.transport.v2',
            encoded[#encoded].schema)

        dfhack.dwarfspec.quarantine = {
            active=true, run_id=active.run_id,
            generation=active.generation, reason='fixture quarantine',
        }
        lines = {}
        load_host_script('recover_executor')(
            active.run_id, tostring(active.generation),
            tostring(#active.event_journal.events), 'fixture verified clean')
        assert.same({'DWARFSPEC_JSON {"encoded":true}'}, lines)
        assert.equals('dwarfspec.transport.v2', encoded[#encoded].schema)
        assert.is_false(encoded[#encoded].scheduler.quarantine.active)
        assert.is_false(dfhack.dwarfspec.quarantine.active)

        lines = {}
        load_host_script('scheduler_status')()
        assert.equals('DWARFSPEC_JSON {"encoded":true}', lines[1])
        assert.equals('dwarfspec.status.v1',
            encoded[#encoded].schema)
        assert.is_true(encoded[#encoded].service_loaded)
        assert.equals('dwarfspec.scheduler.v2',
            encoded[#encoded].scheduler.schema)
    end)
end)
