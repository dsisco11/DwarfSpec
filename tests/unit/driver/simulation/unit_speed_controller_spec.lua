local module = require('dwarfspec.driver.simulation.unit_speed_controller')

describe('driver unit speed controller', function()
    ---Creates controller doubles with observable side effects.
    ---@return table, table
    local function fixture()
        local state = {
            ready=true,
            active=false,
            starts=0,
            stops=0,
            cleanups={},
            defaults={7, 2},
            explicit_calls={},
            explicit_failure=nil,
            available={},
            update_callback=nil,
            retained=nil,
        }
        local recurring = {}
        ---Returns whether recurring work is active.
        ---@return boolean
        function recurring:is_active() return state.active end
        ---Starts recurring work.
        ---@param callback function
        ---@param retained integer[]
        function recurring:start(callback, retained)
            state.starts = state.starts + 1
            state.active = true
            state.update_callback = callback
            state.retained = retained
        end
        ---Stops recurring work.
        function recurring:stop()
            state.stops = state.stops + 1
            state.active = false
        end
        local targets = {
            assert_ready=function()
                assert(state.ready, 'not ready')
            end,
            capture_default_ids=function()
                local result = {}
                for i, id in ipairs(state.defaults) do result[i] = id end
                table.sort(result)
                return result
            end,
            capture_explicit_ids=function(_, ids)
                for i, id in ipairs(ids) do state.explicit_calls[i] = id end
                if state.explicit_failure then error(state.explicit_failure) end
                local result = {}
                for i, id in ipairs(ids) do result[i] = id end
                return result
            end,
            for_each_available=function(_, ids, callback)
                if not state.ready then return false end
                for _, id in ipairs(ids) do
                    local unit = state.available[id]
                    if unit then callback(unit, id) end
                end
                return true
            end,
        }
        local controller = module.new({
            recurring=recurring,
            targets=targets,
            register_cleanup=function(name, callback)
                state.cleanups[#state.cleanups + 1] = {
                    name=name,
                    callback=callback,
                }
            end,
        })
        return state, controller
    end

    ---Asserts activation fails without creating runtime ownership.
    ---@param value any
    ---@param pattern string
    local function assert_validation_failure(value, pattern)
        local state, controller = fixture()
        local ok, failure = pcall(function() controller:activate(value) end)
        assert.is_false(ok)
        assert.matches(pattern, failure, 1, true)
        assert.equals(0, state.starts)
        assert.equals(0, #state.cleanups)
        assert.is_false(controller.active)
    end

    it('accepts every enabled behavior combination', function()
        for _, options in ipairs({
            {fast_actions=true},
            {teleport_jobs=true},
            {fast_actions=true, teleport_jobs=true},
        }) do
            local state, controller = fixture()
            controller:activate(options)
            assert.is_true(controller.active)
            assert.equals(1, state.starts)
        end
    end)

    it('rejects missing, unknown, disabled, and mistyped flags', function()
        assert_validation_failure(nil, 'options must be a table')
        assert_validation_failure({}, 'requires fast_actions or teleport_jobs')
        assert_validation_failure({fast_actions=false, teleport_jobs=false},
            'requires fast_actions or teleport_jobs')
        assert_validation_failure({fast_actions='yes'},
            'fast_actions must be a boolean')
        assert_validation_failure({teleport_jobs=1},
            'teleport_jobs must be a boolean')
        assert_validation_failure({fast_actions=true, surprise=true},
            'unsupported setUnitSpeed option: surprise')
    end)

    it('rejects invalid unit id collection shapes and duplicates', function()
        assert_validation_failure({fast_actions=true, unit_ids='1'},
            'unit_ids must be a nonempty array')
        assert_validation_failure({fast_actions=true, unit_ids={}},
            'unit_ids must be a nonempty array')
        assert_validation_failure({fast_actions=true, unit_ids={[1]=1, [3]=3}},
            'unit_ids must be a dense array')
        assert_validation_failure({fast_actions=true, unit_ids={1, 1}},
            'duplicate id: 1')
        assert_validation_failure({fast_actions=true, unit_ids={1, 2.5}},
            'contain only integer ids')
        assert_validation_failure({fast_actions=true, unit_ids={1, '2'}},
            'contain only integer ids')
    end)

    it('copies and freezes caller options and explicit ids', function()
        local state, controller = fixture()
        local ids = {-4, 9}
        local options = {fast_actions=true, unit_ids=ids}
        controller:activate(options)
        options.fast_actions = false
        options.teleport_jobs = true
        ids[1] = 100
        ids[3] = 200

        assert.is_true(controller.configuration.fast_actions)
        assert.is_false(controller.configuration.teleport_jobs)
        assert.same({-4, 9}, state.explicit_calls)
        assert.same({-4, 9}, state.retained)
        assert.equals(-4, controller.target_ids[1])
        assert.has_error(function()
            controller.configuration.fast_actions = false
        end, 'normalized unit-speed configuration is immutable')
        assert.has_error(function()
            controller.target_ids[1] = 10
        end, 'normalized unit-speed configuration is immutable')
    end)

    it('uses one deterministic default snapshot without later expansion', function()
        local state, controller = fixture()
        state.available[2] = {id=2}
        state.available[7] = {id=7}
        local visited = {}
        controller:activate({fast_actions=true}, function(_, _, id)
            visited[#visited + 1] = id
        end)
        state.defaults[#state.defaults + 1] = 10
        state.available[10] = {id=10}
        state.update_callback()

        assert.same({2, 7}, visited)
        assert.same({2, 7}, state.retained)
    end)

    it('uses an explicit subset and skips unavailable targets on each update',
            function()
        local state, controller = fixture()
        state.available[8] = {generation=1}
        state.available[3] = {generation=1}
        local visited = {}
        controller:activate({teleport_jobs=true, unit_ids={8, 3}},
            function(unit, configuration, id)
                visited[#visited + 1] = {id=id, unit=unit,
                    teleport=configuration.teleport_jobs}
            end)
        state.update_callback()
        state.available[8] = {generation=2}
        state.available[3] = nil
        state.update_callback()

        assert.same({8, 3}, state.retained)
        assert.equals(3, #visited)
        assert.equals(2, visited[3].unit.generation)
        assert.is_true(visited[3].teleport)
    end)

    it('rejects a second activation until cleanup releases ownership', function()
        local state, controller = fixture()
        controller:activate({fast_actions=true})
        local ok, failure = pcall(function()
            controller:activate({teleport_jobs=true})
        end)
        assert.is_false(ok)
        assert.matches('already active', failure, 1, true)
        assert.equals(1, state.starts)

        state.active = false
        state.cleanups[1].callback()
        controller:activate({teleport_jobs=true})
        assert.equals(2, state.starts)
    end)

    it('fails readiness before cleanup or scheduling and preserves game state',
            function()
        local state, controller = fixture()
        state.ready = false
        state.pause = true
        state.tps = 250
        local ok = pcall(function()
            controller:activate({fast_actions=true})
        end)
        assert.is_false(ok)
        assert.equals(0, state.starts)
        assert.equals(0, #state.cleanups)
        assert.is_true(state.pause)
        assert.equals(250, state.tps)
    end)

    it('propagates target validation before cleanup or scheduling', function()
        local state, controller = fixture()
        state.explicit_failure =
            'invalid unit ids: 20; ineligible unit ids: 30'

        local ok, failure = pcall(function()
            controller:activate({fast_actions=true, unit_ids={20, 30}})
        end)

        assert.is_false(ok)
        assert.matches('invalid unit ids: 20', failure, 1, true)
        assert.matches('ineligible unit ids: 30', failure, 1, true)
        assert.equals(0, state.starts)
        assert.equals(0, #state.cleanups)
    end)

    it('stops without visiting units after loaded state disappears', function()
        local state, controller = fixture()
        local visits = 0
        controller:activate({fast_actions=true}, function()
            visits = visits + 1
        end)
        state.ready = false
        state.update_callback()

        assert.equals(0, visits)
        assert.equals(1, state.stops)
        assert.is_false(controller.active)
        assert.is_nil(controller.configuration)
        assert.is_nil(controller.target_ids)
    end)
end)
