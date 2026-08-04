local module = require('dwarfspec.driver.simulation.unit_action_adapter')

describe('driver unit action adapter', function()
    it('calls the native group timer operation with one tick and All', function()
        local calls = {}
        local all = {}
        local adapter = module.new({
            set_group_action_timers=function(unit, amount, group)
                calls[#calls + 1] = {unit=unit, amount=amount, group=group}
            end,
            all_action_group=all,
        })
        local unit = {id=12}

        adapter:accelerate(unit)

        assert.equals(1, #calls)
        assert.equals(unit, calls[1].unit)
        assert.equals(1, calls[1].amount)
        assert.equals(all, calls[1].group)
    end)

    it('rejects incomplete native dependencies before mutation', function()
        assert.has_error(function() module.new({}) end,
            'unit action adapter requires set_group_action_timers')
        assert.has_error(function()
            module.new({set_group_action_timers=function() end})
        end, 'unit action adapter requires all_action_group')
    end)

    it('propagates native failures for recurring fault containment', function()
        local adapter = module.new({
            set_group_action_timers=function()
                error('native timer invariant failed')
            end,
            all_action_group='All',
        })

        assert.has_error(function() adapter:accelerate({id=1}) end,
            'native timer invariant failed')
    end)
end)
