-- Unit contracts for shared native title-menu inspection and navigation.

local title_menu = require('dwarfspec.driver.commands.title_menu')

describe('native title-menu adapter', function()
    local modes
    local screen
    local native_game
    local inputs
    local waits

    before_each(function()
        modes = {
            MAIN_MENU=10,
            CONTINUE_ACTIVE_WORLD=20,
            CONTINUE_ACTIVE=30,
        }
        screen = {mode=modes.MAIN_MENU}
        native_game = {
            current_viewscreen=function() return screen end,
            title_screen_type={
                is_instance=function(_, candidate)
                    return candidate == screen
                end,
            },
            title_mode_type=modes,
        }
        inputs = {}
        waits = {}
    end)

    it('normalizes supported title modes and rejects non-title screens',
            function()
        assert.equals('main', title_menu.read(native_game).mode)
        screen.mode = modes.CONTINUE_ACTIVE_WORLD
        assert.equals('world-list', title_menu.read(native_game).mode)
        screen.mode = modes.CONTINUE_ACTIVE
        assert.equals('save-list', title_menu.read(native_game).mode)

        native_game.title_screen_type.is_instance = function() return false end
        assert.is_nil(title_menu.read(native_game))
    end)

    it('returns immediately from the main menu without input', function()
        local state = title_menu.reach_main_menu(native_game,
            function() error('unexpected title input') end,
            function() error('unexpected title wait') end)

        assert.equals('main', state.mode)
    end)

    it('navigates bounded title submenus to the main menu', function()
        screen.mode = 40
        local transitions = {
            [40]=modes.CONTINUE_ACTIVE_WORLD,
            [modes.CONTINUE_ACTIVE_WORLD]=modes.MAIN_MENU,
        }

        local state = title_menu.reach_main_menu(native_game,
            function(actual_screen, key)
                assert.equals(screen, actual_screen)
                table.insert(inputs, key)
                actual_screen.mode = transitions[actual_screen.mode]
            end,
            function(description, query)
                table.insert(waits, description)
                return assert(query())
            end)

        assert.equals('main', state.mode)
        assert.same({'LEAVESCREEN', 'LEAVESCREEN'}, inputs)
        assert.same({
            'return to title main menu',
            'return to title main menu',
        }, waits)
    end)

    it('rejects an unrecognized non-title screen', function()
        native_game.title_screen_type.is_instance = function() return false end

        assert.has_error(function()
            title_menu.reach_main_menu(native_game, function() end,
                function() end)
        end, 'DwarfSpec title-menu navigation requires the title screen')
    end)
end)
