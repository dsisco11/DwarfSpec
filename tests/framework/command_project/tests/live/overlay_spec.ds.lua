-- Live proof that command-selected overlay fixtures are staged and rescanned.

local overlay = require('plugins.overlay')

describe('command runner overlay path', function()
    it('loads the uniquely named staged overlay fixture', function()
        local found = false
        local names = {}
        for name in pairs(overlay.get_state().db) do
            table.insert(names, name)
            if name:match(
                    'gui/dwarfspec_.*_runner_probe%.runner_probe$') then
                found = true
                break
            end
        end
        table.sort(names)
        assert.is_true(found, 'registered overlays: ' .. table.concat(names,
            ', '))
    end)
end)
