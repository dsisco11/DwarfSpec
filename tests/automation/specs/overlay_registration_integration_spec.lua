-- Real DFHack overlay registration integration, intentionally run separately.

local overlay = require('plugins.overlay')

local staged
local broad_name
local filtered_name
local config_existed
local config_contents
local config_path

---Reads one complete binary file for exact restoration comparison.
---@param path string
---@return string
local function read_file(path)
    local file, open_error = io.open(path, 'rb')
    assert(file, open_error)
    local contents = file:read('*a')
    file:close()
    return contents
end

describe('real overlay registration integration', function()
    it('discovers, enables, positions, and focus-filters registered widgets',
            function()
        local run = assert(dfhack.dwarfspec.active_run)
        local stage = assert(run.overlay_registration_integration,
            'internal overlay registration support is unavailable')
        run.overlay_registration_events = {}
        config_path = dfhack.getDFPath() .. '/dfhack-config/overlay.json'
        config_existed = dfhack.filesystem.isfile(config_path)
        config_contents = config_existed and read_file(config_path) or nil

        staged = stage(
            'tests/automation/overlay_integration/' ..
                'registration_probe.definition.lua')
        broad_name = 'gui/' .. staged.script_name .. '.broad'
        filtered_name = 'gui/' .. staged.script_name .. '.filtered'
        assert.same({broad_name, filtered_name}, staged.registered_names)

        local state = overlay.get_state()
        local broad = assert(state.db[broad_name]).widget
        local filtered = assert(state.db[filtered_name]).widget
        assert.is_false(state.config[broad_name].enabled)
        assert.is_false(state.config[filtered_name].enabled)

        assert.is_true(overlay.overlay_command(
            {'enable', broad_name, filtered_name}, true))
        assert.is_true(state.config[broad_name].enabled)
        assert.is_true(state.config[filtered_name].enabled)
        assert.equals(1, run.overlay_registration_events.broad_enabled)
        assert.equals(1, run.overlay_registration_events.filtered_enabled)

        assert.is_true(overlay.overlay_command(
            {'position', broad_name, '7', '-4'}, true))
        assert.same({x=7, y=-4}, state.config[broad_name].pos)
        assert.equals(6, broad.frame.l)
        assert.equals(3, broad.frame.b)

        broad.update_count = 0
        filtered.update_count = 0
        overlay.update_viewscreen_widgets('viewscreen_dwarfmodest',
            dfhack.gui.getDFViewscreen(true))
        assert.equals(1, broad.update_count)
        assert.equals(0, filtered.update_count)
    end)

    it('restores every external registration artifact', function()
        local run = assert(dfhack.dwarfspec.active_run)
        assert.is_truthy(staged)
        assert.same({
            complete=true,
            script_removed=true,
            config_restored=true,
            registrations_removed=true,
            failures={},
        }, staged.cleanup_state)
        assert.is_false(dfhack.filesystem.isfile(staged.path))
        assert.is_nil(overlay.get_state().db[broad_name])
        assert.is_nil(overlay.get_state().db[filtered_name])
        assert.equals(1, run.overlay_registration_events.broad_disabled)
        assert.equals(1, run.overlay_registration_events.filtered_disabled)
        assert.equals(config_existed,
            dfhack.filesystem.isfile(config_path))
        if config_existed then
            assert.equals(config_contents, read_file(config_path))
        end
    end)
end)
