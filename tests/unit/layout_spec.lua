local layout = require('dwarfspec.layout')

describe('package layout', function()
    it('recognizes the checkout after automation modules move under src',
        function()
            local current = layout.current()
            local package_root = current.package_root:gsub('\\', '/')

            assert.is_nil(package_root:match('/src$'))
            assert.are.equal(
                package_root ..
                    '/src/dwarfspec/automation/bootstrap.lua',
                current.host_scripts.bootstrap:gsub('\\', '/'))
        end)
end)
