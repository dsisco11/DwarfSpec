local ds_factory = assert(loadfile('src/dwarfspec/ds.lua'))()

describe('unit command source and installed composition', function()
    ---Binds both focused commands and records their shared-controller calls.
    ---@param load_module fun(name:string):table
    ---@return table, table
    local function bind_commands(load_module)
        local ds = {}
        local calls = {}
        local positions = {move=function(_, id, position)
            calls[#calls + 1] = {'position', id, position}
            return true
        end}
        local speed = {activate=function(_, options)
            calls[#calls + 1] = {'speed', options}
        end}
        load_module('unit_speed').bind(ds, {controller=speed})
        load_module('unit_position').bind(ds,
            {position_controller=positions})
        return ds, calls
    end

    it('loads the same focused public contract by either layout', function()
        local modules = {
            unit_speed=require('dwarfspec.driver.commands.unit_speed'),
            unit_position=require('dwarfspec.driver.commands.unit_position'),
        }
        local source_paths = {}
        local required_names = {}
        local source_ds, source_calls = bind_commands(function(name)
            return ds_factory.load_automation_module('/package',
                'dwarfspec.driver.commands.' .. name, {
                    open_file=function(path)
                        source_paths[#source_paths + 1] = path
                        return {close=function() end}
                    end,
                    load_file=function()
                        return function() return modules[name] end
                    end,
                    require_module=function()
                        error('source composition unexpectedly required a module')
                    end,
                })
        end)
        local installed_ds, installed_calls = bind_commands(function(name)
            return ds_factory.load_automation_module('/package',
                'dwarfspec.driver.commands.' .. name, {
                    open_file=function() return nil end,
                    load_file=function()
                        error('installed composition unexpectedly loaded source')
                    end,
                    require_module=function(module_name)
                        required_names[#required_names + 1] = module_name
                        return modules[name]
                    end,
                })
        end)
        local options = {fast_actions=true}
        local position = {x=1, y=2, z=3}
        assert.is_nil(source_ds.setUnitSpeed(options))
        assert.is_nil(source_ds.setUnitPos(7, position))
        assert.is_nil(installed_ds.setUnitSpeed(options))
        assert.is_nil(installed_ds.setUnitPos(7, position))
        assert.same(source_calls, installed_calls)
        assert.same({
            '/package/src/dwarfspec/driver/commands/unit_speed.lua',
            '/package/src/dwarfspec/driver/commands/unit_position.lua',
        }, source_paths)
        assert.same({
            'dwarfspec.driver.commands.unit_speed',
            'dwarfspec.driver.commands.unit_position',
        }, required_names)
    end)
end)
