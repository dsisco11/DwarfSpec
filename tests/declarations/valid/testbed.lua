---Exercises valid TestBed construction and descriptor-mount declarations.
---@return fun()
local function declaration_fixture()
    return function()
        ---@type dwarfspec.ComponentClass
        local TestWidget = {}
        local TestBed = require('dwarfspec.testbed')
        local bed = TestBed.new()
        local configured = TestBed.new({
            module_roots={'src'},
            globals={answer=42},
            imports={
                {provide={kind='module', name='value'}, use_value=true},
                {provide={kind='script', name='source'}, use_source='source.lua'},
                {provide={kind='module', name='host'}, use_host=true},
                {provide={kind='script', name='alias'}, use_existing={
                    kind='script', name='source',
                }},
            },
        })
        local value, loader_data = bed:require('value')
        assert(value == nil or loader_data == nil or type(loader_data) == 'string')
        bed:close()
        configured:close()

        ds.mount(TestWidget, {viewport={width=80, height=25}})
        ds.mount({kind='module', name='consumer.widget'}, nil, {
            component_imports=false,
        })
        ds.mount({kind='script', name='consumer/widget', export='Widget'}, {
            viewport={width=80, height=25},
        }, {script_roots={'scripts'}})
    end
end

return declaration_fixture
