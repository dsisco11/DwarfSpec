---Supplies invalid TestBed and descriptor-mount declaration examples.
---@return fun()
local function invalid_declaration_fixture()
    return function()
        local TestBed = require('dwarfspec.testbed')
        TestBed.new({component_imports='yes'})
        TestBed.new({imports={{provide={kind='module'}, use_value=true}}})
        TestBed.new({imports={{provide={kind='module', name='nil'}, use_value=nil}}})
        ds.mount({kind='module'}, nil)
        ds.mount({kind='module', name='consumer'}, nil, TestBed.new())
    end
end

return invalid_declaration_fixture
