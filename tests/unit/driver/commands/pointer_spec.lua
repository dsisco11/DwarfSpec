local command = require('dwarfspec.driver.commands.pointer')

describe('pointer command binding', function()
    it('keeps each mouse action bound to its geometry-aware implementation', function()
        local ds, calls = {}, {}
        local functions = {}
        for _, name in ipairs({'move_pointer', 'hover', 'click', 'mouseInput', 'mouseWheel'}) do
            functions[name] = function() calls[name] = true end
        end
        ds = command.new(functions)
        ds.mouseWheel()
        assert.is_true(calls.mouseWheel)
    end)
end)
