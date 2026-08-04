local module = require('dwarfspec.driver.commands.unit_speed')

describe('driver unit speed command', function()
    it('returns nil after activating the injected controller', function()
        local ds = {}
        local received
        module.bind(ds, {controller={activate=function(_, options)
            received = options
        end}})
        local options = {fast_actions=true, unit_ids={4}}
        local result = ds.setUnitSpeed(options)
        assert.is_nil(result)
        assert.equals(options, received)
    end)

    it('propagates controller validation failures', function()
        local ds = {}
        module.bind(ds, {controller={activate=function()
            error('invalid unit-speed options')
        end}})
        assert.has_error(function()
            ds.setUnitSpeed({})
        end, 'invalid unit-speed options')
    end)
end)
