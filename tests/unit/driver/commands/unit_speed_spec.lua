local module = require('dwarfspec.driver.commands.unit_speed')
local cleanup = require('dwarfspec.host.execution.cleanup')
local game_state = require('dwarfspec.driver.commands.game_state')

describe('driver unit speed command', function()
    it('returns nil after activating the injected controller', function()
        local ds = {}
        local received
        module.bind(ds, {controller={activate=function(_, options)
            received = options
            return false
        end}, enable_fast_movement=function()
            error('fast movement was not requested')
        end})
        local options = {fast_actions=true, unit_ids={4}}
        local result = ds.setUnitSpeed(options)
        assert.is_nil(result)
        assert.equals(options, received)
    end)

    it('propagates controller validation failures', function()
        local ds = {}
        module.bind(ds, {controller={activate=function()
            error('invalid unit-speed options')
        end}, enable_fast_movement=function() end})
        assert.has_error(function()
            ds.setUnitSpeed({})
        end, 'invalid unit-speed options')
    end)

    it('enables native turbo speed only when fast movement is requested',
            function()
        local ds = {}
        local calls = 0
        module.bind(ds, {controller={activate=function(_, options)
            return options.fast_movement
        end}, enable_fast_movement=function()
            calls = calls + 1
        end})

        ds.setUnitSpeed({fast_actions=true})
        ds.setUnitSpeed({fast_movement=true})

        assert.equals(1, calls)
    end)

    it('restores turbo speed after fast-movement cleanup', function()
        local original_df = rawget(_G, 'df')
        local registry = cleanup.new({})
        local ds = {}
        rawset(_G, 'df', {global={debug_turbospeed=false}})
        game_state.bind(ds, {
            context={},
            cleanup_module=cleanup,
            cleanup_registry=registry,
        })
        module.bind(ds, {controller={activate=function(_, options)
            return options.fast_movement
        end}, enable_fast_movement=function()
            return ds.setTurboSpeed(true)
        end})

        local ok, failure = pcall(function()
            ds.setUnitSpeed({fast_movement=true})
            assert.is_true(df.global.debug_turbospeed)
            assert.equals(1, cleanup.pending_count(registry))
            assert.is_true(cleanup.run(registry, 'fast-movement cleanup'))
            assert.is_false(df.global.debug_turbospeed)
            assert.equals(0, cleanup.pending_count(registry))
        end)
        rawset(_G, 'df', original_df)
        assert.is_true(ok, failure)
    end)
end)
