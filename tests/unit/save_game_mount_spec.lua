-- Unit contracts for save-game mount validation and current-world preflight.

local save_game_mount = assert(loadfile(
    'src/dwarfspec/automation/save_game_mount.lua'))()

describe('save-game mount preflight', function()
    local world_loaded
    local loaded_directory
    local read_calls
    local cleanup_registrations
    local dependencies

    ---Builds one injected world-state adapter for the preflight operation.
    ---@return table
    local function make_dependencies()
        return {
            is_world_loaded=function() return world_loaded end,
            read_world_folder=function()
                read_calls = read_calls + 1
                return loaded_directory
            end,
            register_cleanup=function()
                cleanup_registrations = cleanup_registrations + 1
            end,
        }
    end

    before_each(function()
        world_loaded = true
        loaded_directory = 'region1'
        read_calls = 0
        cleanup_registrations = 0
        dependencies = make_dependencies()
    end)

    it('accepts one ordinary save directory name', function()
        assert.equals('region42', save_game_mount.validate_directory_name(1,
            'region42'))
    end)

    it('rejects missing, extra, empty, and non-string arguments', function()
        assert.has_error(function()
            save_game_mount.validate_directory_name(0, nil)
        end, 'DwarfSpec mountSaveGame requires exactly one save directory name')
        assert.has_error(function()
            save_game_mount.validate_directory_name(2, 'region1')
        end, 'DwarfSpec mountSaveGame requires exactly one save directory name')
        assert.has_error(function()
            save_game_mount.validate_directory_name(1, '')
        end, 'DwarfSpec mountSaveGame requires a nonempty save directory name')
        assert.has_error(function()
            save_game_mount.validate_directory_name(1, 42)
        end, 'DwarfSpec mountSaveGame requires a nonempty save directory name')
    end)

    it('rejects paths and traversal names', function()
        for _, invalid_name in ipairs({'.', '..', '../region1',
                'save/region1', 'save\\region1', 'C:region1', '\0'}) do
            assert.has_error(function()
                save_game_mount.validate_directory_name(1, invalid_name)
            end, 'DwarfSpec mountSaveGame requires one directory name, not a path')
        end
    end)

    it('returns a no-transition result for the already loaded save', function()
        local result = save_game_mount.preflight(dependencies, 1, 'region1')

        assert.same({
            requested_directory='region1',
            loaded_directory='region1',
            transition_required=false,
        }, result)
        assert.equals(1, read_calls)
        assert.equals(0, cleanup_registrations)
    end)

    it('requires a transition for a different loaded save', function()
        local result = save_game_mount.preflight(dependencies, 1, 'region2')

        assert.same({
            requested_directory='region2',
            loaded_directory='region1',
            transition_required=true,
        }, result)
        assert.equals(1, read_calls)
    end)

    it('requires loading without reading a directory when no world is loaded',
            function()
        world_loaded = false

        local result = save_game_mount.preflight(dependencies, 1, 'region2')

        assert.same({
            requested_directory='region2',
            loaded_directory=nil,
            transition_required=true,
        }, result)
        assert.equals(0, read_calls)
    end)

    it('reports missing world-state APIs and invalid loaded directories',
            function()
        assert.has_error(function()
            save_game_mount.preflight({}, 1, 'region1')
        end, 'DwarfSpec mountSaveGame requires dfhack.isWorldLoaded')

        dependencies.read_world_folder = nil
        assert.has_error(function()
            save_game_mount.preflight(dependencies, 1, 'region1')
        end, 'DwarfSpec mountSaveGame requires dfhack.world.ReadWorldFolder')

        dependencies = make_dependencies()
        loaded_directory = ''
        assert.has_error(function()
            save_game_mount.preflight(dependencies, 1, 'region1')
        end, 'DFHack ReadWorldFolder did not return a valid save directory name')
    end)
end)
