---Supplies an invalid TestBed provider with an unsupported strategy field.
---@return fun()
local function unknown_strategy_declaration_fixture()
    return function()
        local TestBed = require('dwarfspec.testbed')
        TestBed.new({imports={{provide={kind='module', name='value'},
            use_unknown=true}}})
    end
end

return unknown_strategy_declaration_fixture
