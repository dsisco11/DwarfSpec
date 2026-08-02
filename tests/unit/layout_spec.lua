local layout = require('dwarfspec.layout')

local host_script_names = {
    'bootstrap', 'status', 'recover', 'recover_executor',
    'scheduler_status', 'run_query', 'abort', 'acknowledge', 'probe',
    'cancel', 'discard', 'event_read',
}

---Returns a normalized path for stable cross-platform assertions.
---@param path string
---@return string
local function normalized(path)
    return path:gsub('\\', '/')
end

describe('package layout', function()
    it('recognizes the checkout after automation modules move under src',
        function()
            local current = layout.current()
            local package_root = current.package_root:gsub('\\', '/')

            assert.is_nil(package_root:match('/src$'))
            for _, name in ipairs(host_script_names) do
                assert.is_true(current.host_scripts[name] ~= nil)
                assert.is_true(
                    normalized(current.host_scripts[name]):match(
                        '^' .. package_root ..
            '/src/dwarfspec/host/entrypoints/' .. name .. '%.lua$') ~= nil)
            end
        end)

    it('derives installed entry paths from the installed module root',
            function()
        local lfs = require('lfs')
        local temporary_root = os.tmpname()
        os.remove(temporary_root)
        assert(lfs.mkdir(temporary_root))
        local lua_root = temporary_root .. '/share/lua/5.4/dwarfspec'
        assert(lfs.mkdir(temporary_root .. '/share'))
        assert(lfs.mkdir(temporary_root .. '/share/lua'))
        assert(lfs.mkdir(temporary_root .. '/share/lua/5.4'))
        assert(lfs.mkdir(lua_root))
        assert(lfs.mkdir(lua_root .. '/host'))
        assert(lfs.mkdir(lua_root .. '/host/entrypoints'))
        local bootstrap = assert(io.open(
            lua_root .. '/host/entrypoints/bootstrap.lua', 'wb'))
        bootstrap:close()

        local original_getinfo = debug.getinfo
        debug.getinfo = function(level, what)
            if what == 'S' then
                return {source='@' .. lua_root .. '/layout.lua'}
            end
            return original_getinfo(level, what)
        end
        local ok, result = xpcall(layout.current, debug.traceback)
        debug.getinfo = original_getinfo
        os.remove(lua_root .. '/host/entrypoints/bootstrap.lua')
        lfs.rmdir(lua_root .. '/host/entrypoints')
        lfs.rmdir(lua_root .. '/host')
        lfs.rmdir(lua_root)
        lfs.rmdir(temporary_root .. '/share/lua/5.4')
        lfs.rmdir(temporary_root .. '/share/lua')
        lfs.rmdir(temporary_root .. '/share')
        lfs.rmdir(temporary_root)

        assert.is_true(ok, result)
        for _, name in ipairs(host_script_names) do
            assert.equals(
                normalized(lua_root .. '/host/entrypoints/' .. name .. '.lua'),
                normalized(result.host_scripts[name]))
        end
    end)
end)
