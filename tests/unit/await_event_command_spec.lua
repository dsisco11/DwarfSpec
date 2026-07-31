-- Unit contracts for the native state-change event command binding.

local EEvent = require('dwarfspec.state_change_events')
local command_module = require('dwarfspec.commands.await_event')

describe('awaitEvent command binding', function()
    local constants
    local handlers
    local scheduler
    local scheduler_module
    local save_directory
    local focus
    local screen
    local wait_event_calls
    local accepted_occurrence
    local active_identity
    local awaited_event
    local wait_behavior
    local command

    ---Returns the only installed native listener and its key.
    ---@return function, string
    local function installed_listener()
        local listener
        local listener_key
        local count = 0
        for key, value in pairs(handlers) do
            count = count + 1
            listener = value
            listener_key = key
        end
        assert.equals(1, count)
        return listener, listener_key
    end

    ---Copies one immutable scalar record for ordinary table assertions.
    ---@param record table
    ---@return table
    local function record_values(record)
        local values = {}
        for name, value in pairs(record) do values[name] = value end
        return values
    end

    before_each(function()
        constants = {
            WORLD_LOADED=101,
            WORLD_UNLOADED=102,
            MAP_LOADED=103,
            MAP_UNLOADED=104,
            VIEWSCREEN_CHANGED=105,
            PAUSED=107,
            UNPAUSED=108,
        }
        handlers = {}
        scheduler = {}
        save_directory = 'region1'
        focus = {'dwarfmode/Default'}
        screen = {
            _type={_name='viewscreen_dwarfmodest'},
            transient_pointer={address='native'},
        }
        wait_event_calls = 0
        accepted_occurrence = nil
        active_identity = nil
        awaited_event = nil
        wait_behavior = 'signal'
        scheduler_module = {
            wait_event=function(observed_scheduler, event, options)
                assert.equals(scheduler, observed_scheduler)
                wait_event_calls = wait_event_calls + 1
                awaited_event = event
                active_identity = {}
                local armed, arm_error =
                    pcall(options.arm, active_identity)
                if not armed then
                    options.cleanup()
                    error(arm_error, 0)
                end
                if wait_behavior == 'cancel' then
                    options.cleanup()
                    options.cleanup()
                    error('fixture cancellation', 0)
                end
                assert.is_not_nil(accepted_occurrence,
                    'fixture event was not signaled')
                options.cleanup()
                options.cleanup()
                return accepted_occurrence
            end,
            signal_event=function(observed_scheduler, identity, occurrence)
                assert.equals(scheduler, observed_scheduler)
                if identity ~= active_identity or
                        occurrence.event ~= awaited_event or
                        accepted_occurrence ~= nil then
                    return false
                end
                accepted_occurrence = occurrence
                return true
            end,
        }
        command = command_module.new({
            events=EEvent,
            state_changes=constants,
            state_change_handlers=handlers,
            scheduler_module=scheduler_module,
            scheduler=scheduler,
            read_save_directory=function()
                return save_directory
            end,
            get_focus=function() return focus end,
            current_viewscreen=function() return screen end,
        })
    end)

    local mapping_cases = {
        {
            name='world loaded',
            event=EEvent.WORLD_LOADED,
            state='WORLD_LOADED',
            payload={save_directory='region1'},
        },
        {
            name='world unloaded',
            event=EEvent.WORLD_UNLOADED,
            state='WORLD_UNLOADED',
            payload={save_directory='region1'},
            unload=true,
        },
        {
            name='map loaded',
            event=EEvent.MAP_LOADED,
            state='MAP_LOADED',
            payload={save_directory='region1'},
        },
        {
            name='map unloaded',
            event=EEvent.MAP_UNLOADED,
            state='MAP_UNLOADED',
            payload={save_directory='region1'},
            unload=true,
        },
        {
            name='viewscreen changed',
            event=EEvent.VIEWSCREEN_CHANGED,
            state='VIEWSCREEN_CHANGED',
            payload={
                focus='dwarfmode/Default',
                native_screen_type='viewscreen_dwarfmodest',
            },
        },
        {
            name='paused',
            event=EEvent.PAUSED,
            state='PAUSED',
            payload={paused=true},
        },
        {
            name='unpaused',
            event=EEvent.UNPAUSED,
            state='UNPAUSED',
            payload={paused=false},
        },
    }

    for _, case in ipairs(mapping_cases) do
        it('maps and snapshots ' .. case.name, function()
            local result = command(case.event, {
                trigger=function()
                    local listener = installed_listener()
                    if case.unload then save_directory = nil end
                    listener(constants[case.state])
                end,
            })

            assert.equals(case.event, result.event)
            assert.equals('state_change', result.source)
            assert.same(case.payload, record_values(result.payload))
            assert.same({}, handlers)
        end)
    end

    it('validates public arguments before listener registration', function()
        local cases = {
            {
                event='unsupported',
                options=nil,
                expected='awaitEvent does not support event: "unsupported"',
            },
            {
                event=EEvent.PAUSED,
                options='invalid',
                expected='awaitEvent options must be a table; ' ..
                    'received "invalid"',
            },
            {
                event=EEvent.PAUSED,
                options={unknown=true},
                expected='awaitEvent options contain unsupported field: ' ..
                    '"unknown"',
            },
            {
                event=EEvent.PAUSED,
                options={trigger=true},
                expected='awaitEvent trigger must be a function',
            },
            {
                event=EEvent.PAUSED,
                options={description=''},
                expected='awaitEvent description must be a nonempty string',
            },
            {
                event=EEvent.PAUSED,
                options={timeout_ms=0},
                expected='awaitEvent timeout_ms must be false or a positive integer',
            },
            {
                event=EEvent.PAUSED,
                options={timeout_ms=1.5},
                expected='awaitEvent timeout_ms must be false or a positive integer',
            },
        }
        for _, case in ipairs(cases) do
            assert.has_error(function()
                command(case.event, case.options)
            end, case.expected)
        end

        assert.equals(0, wait_event_calls)
        assert.same({}, handlers)
    end)

    it('uses bounded diagnostics for malformed public values', function()
        local long_event = string.rep('x', 200)
        local ok, command_error = pcall(command, long_event)

        assert.is_false(ok)
        assert.is_true(#command_error < 180)
        assert.matches('xxx%.%.%."', command_error)
        assert.same({}, handlers)
    end)

    it('arms before the trigger and captures a synchronous event', function()
        local observed_key
        local result = command(EEvent.PAUSED, {
            description='pause proof',
            timeout_ms=false,
            trigger=function()
                local listener, key = installed_listener()
                observed_key = key
                listener(constants.PAUSED)
                assert.same({}, handlers)
            end,
        })

        assert.matches('^dwarfspec%.awaitEvent%.%d+$', observed_key)
        assert.is_true(result.payload.paused)
        assert.same({}, handlers)
    end)

    it('ignores unrelated native state changes', function()
        local signal_count = 0
        local original_signal = scheduler_module.signal_event
        scheduler_module.signal_event =
            function(observed_scheduler, identity, occurrence)
                signal_count = signal_count + 1
                return original_signal(
                    observed_scheduler, identity, occurrence)
            end

        local result = command(EEvent.MAP_LOADED, {
            trigger=function()
                local listener = installed_listener()
                listener(constants.PAUSED)
                assert.is_nil(accepted_occurrence)
                installed_listener()
                listener(constants.MAP_LOADED)
                assert.same({}, handlers)
            end,
        })

        assert.equals(EEvent.MAP_LOADED, result.event)
        assert.equals(1, signal_count)
    end)

    it('removes its listener and preserves a trigger failure', function()
        local ok, command_error = pcall(command, EEvent.PAUSED, {
            trigger=function()
                installed_listener()
                error('trigger exploded')
            end,
        })

        assert.is_false(ok)
        assert.matches('trigger exploded', command_error, 1, true)
        assert.same({}, handlers)
    end)

    it('removes its listener when the scheduler cancels the wait', function()
        wait_behavior = 'cancel'
        local ok, command_error = pcall(command, EEvent.PAUSED)

        assert.is_false(ok)
        assert.matches('fixture cancellation', command_error, 1, true)
        assert.same({}, handlers)
    end)

    it('omits otherwise valid payload fields when unavailable', function()
        save_directory = nil
        focus = nil
        screen = nil

        local loaded = command(EEvent.WORLD_LOADED, {
            trigger=function()
                installed_listener()(constants.WORLD_LOADED)
            end,
        })
        accepted_occurrence = nil
        local changed = command(EEvent.VIEWSCREEN_CHANGED, {
            trigger=function()
                installed_listener()(constants.VIEWSCREEN_CHANGED)
            end,
        })

        assert.same({}, record_values(loaded.payload))
        assert.same({}, record_values(changed.payload))
    end)

    it('treats failing optional native readers as unavailable', function()
        command = command_module.new({
            events=EEvent,
            state_changes=constants,
            state_change_handlers=handlers,
            scheduler_module=scheduler_module,
            scheduler=scheduler,
            read_save_directory=function() error('world unavailable') end,
            get_focus=function() error('focus unavailable') end,
            current_viewscreen=function() error('screen unavailable') end,
        })

        local result = command(EEvent.VIEWSCREEN_CHANGED, {
            trigger=function()
                installed_listener()(constants.VIEWSCREEN_CHANGED)
            end,
        })

        assert.same({}, record_values(result.payload))
    end)

    it('returns immutable pointer-free snapshots', function()
        local result = command(EEvent.VIEWSCREEN_CHANGED, {
            trigger=function()
                installed_listener()(constants.VIEWSCREEN_CHANGED)
            end,
        })

        assert.has_error(function()
            result.event = EEvent.PAUSED
        end, 'event occurrence is immutable')
        assert.has_error(function()
            result.payload.focus = 'mutated'
        end, 'event payload is immutable')
        assert.is_nil(result.payload.transient_pointer)
        screen._type._name = 'mutated_after_callback'
        focus[1] = 'mutated/after/callback'
        assert.equals('viewscreen_dwarfmodest',
            result.payload.native_screen_type)
        assert.equals('dwarfmode/Default', result.payload.focus)
    end)

    it('uses a unique listener key for each wait', function()
        local keys = {}
        for _ = 1, 2 do
            accepted_occurrence = nil
            command(EEvent.PAUSED, {
                trigger=function()
                    local listener, key = installed_listener()
                    table.insert(keys, key)
                    listener(constants.PAUSED)
                end,
            })
        end

        assert.equals(2, #keys)
        assert.is_not.equal(keys[1], keys[2])
        assert.same({}, handlers)
    end)
end)
