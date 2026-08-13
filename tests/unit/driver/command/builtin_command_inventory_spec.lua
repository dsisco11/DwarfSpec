---@class dwarfspec.tests.BuiltinCommandInventory
local Inventory = {}

Inventory.names = {'wait_frames', 'wait_ticks', 'await', 'await_event',
    'is_game_paused', 'get_game_speed', 'get_tick', 'get_time',
    'get_save_directory_name', 'has_focus', 'current_run', 'root', 'get',
    'inspect', 'capture_view_tree', 'capture_screen',
    'subject_get_focus_list', 'subject_raw', 'search', 'click',
    'get_view_pos', 'set_view_pos', 'mount_save_game',
    'stage_overlay_registration', 'register_cleanup', 'set_game_paused',
    'set_game_speed', 'set_turbo_speed', 'set_unit_pos', 'set_unit_speed'}

Inventory.obsolete = {'wait_definition', 'game_query_definition',
    'mount_query_definition', 'subject_query_definition',
    'run_query_definition', 'capture_definition', 'search_definition',
    'click_definition', 'view_position_definition',
    'mount_save_game_definition', 'overlay_registration_definition',
    'game_state', 'unit_position', 'unit_speed'}

---Reads one repository source file.
---@param path string
---@return string
function Inventory.read(path)
    local file = assert(io.open(path, 'rb'))
    local source = file:read('*a')
    file:close()
    return source
end

describe('built-in command source organization', function()
    it('gives every verified built-in exactly one owner module', function()
        local seen = {}
        for _, name in ipairs(Inventory.names) do
            assert.is_nil(seen[name], name)
            seen[name] = true
            local path = 'src/dwarfspec/driver/builtins/' .. name .. '.lua'
            local source = Inventory.read(path)
            assert.is_truthy(source:find(':definition()', 1, true), path)
            assert.is_truthy(source:find(':arguments(', 1, true), path)
            assert.is_nil(source:find('registerBuiltin', 1, true), path)
            assert.is_nil(source:find('function ds.', 1, true), path)
            assert.is_nil(source:find('ds[', 1, true), path)
        end
    end)

    it('removes aggregate definition modules and command-local binding',
            function()
        for _, name in ipairs(Inventory.obsolete) do
            assert.is_nil(io.open('src/dwarfspec/driver/commands/' ..
                name .. '.lua', 'rb'), name)
        end
        local source = Inventory.read('src/dwarfspec/ds.lua')
        assert.is_nil(source:find('_definition_module', 1, true))
        assert.is_nil(source:find('.bind(ds, command_runner', 1, true))
        assert.is_nil(source:find(':registerBuiltin(', 1, true))
        for _, public_name in ipairs({'wait_frames', 'wait_ticks', 'await',
                'awaitEvent', 'isGamePaused', 'getGameSpeed', 'getTick',
                'getTime', 'getSaveDirectoryName', 'hasFocus', 'current_run',
                'root', 'get', 'inspect', 'capture_view_tree',
                'capture_screen', 'search', 'click', 'getViewPos',
                'setViewPos', 'mountSaveGame', 'stage_overlay_registration',
                'registerCleanup', 'setGamePaused', 'setGameSpeed',
                'setTurboSpeed', 'setUnitPos', 'setUnitSpeed'}) do
            assert.is_nil(source:find('function ds.' .. public_name .. '(',
                1, true), public_name)
        end
        local _, count = source:gsub('registrar:register_all%(', '')
        assert.equals(1, count)
        local registered = {}
        for name in source:gmatch('builtin_modules%.([%w_]+)%.new%(') do
            registered[#registered + 1] = name
        end
        assert.same(Inventory.names, registered)
        for _, name in ipairs(Inventory.names) do
            local load = "'dwarfspec.driver.builtins." .. name .. "'"
            local _, load_count = source:gsub(load, '')
            assert.equals(1, load_count, name)
        end
        assert.is_nil(source:find(
            'verified_subject_queries.raw or', 1, true))
        assert.is_nil(source:find(
            'verified_subject_queries.getFocusList or get_focus_list',
            1, true))
    end)

    it('keeps shared scalar mechanics below the owner interface', function()
        local source = Inventory.read(
            'src/dwarfspec/driver/builtins/scalar_query_command.lua')
        assert.is_nil(source:find(':definition(', 1, true))
        assert.is_nil(source:find(':arguments(', 1, true))
        assert.is_truthy(source:find(':build_definition()', 1, true))
    end)

    it('keeps verified mount queries out of the legacy command aggregate',
            function()
        local legacy = Inventory.read(
            'src/dwarfspec/driver/commands/mount.lua')
        for _, name in ipairs({'root', 'get', 'inspect',
                'capture_view_tree'}) do
            assert.is_nil(legacy:find(name .. '=function', 1, true), name)
        end
        local runtime = Inventory.read(
            'src/dwarfspec/driver/runtime/mount_query_runtime.lua')
        assert.is_nil(runtime:find('_commands', 1, true))
        assert.is_nil(runtime:find('options.commands', 1, true))
        local composition = Inventory.read('src/dwarfspec/ds.lua')
        assert.is_nil(composition:find('commands=mount_commands', 1, true))
    end)
end)
