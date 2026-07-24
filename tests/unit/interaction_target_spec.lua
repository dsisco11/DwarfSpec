-- Unit contracts for owned-screen interaction routing.

local interaction_target = assert(loadfile(
    'src/dwarfspec/interaction_target.lua'))()

describe('owned-screen interaction target', function()
    it('routes native input and invalidation without owning cleanup',
            function()
        local native = {name='native'}
        local screen = {
            active=true,
            invalidations=0,
            dismissals=0,
        }

        ---Records one owned-screen invalidation.
        ---@param self table
        function screen:invalidate()
            self.invalidations = self.invalidations + 1
            return 'invalidated'
        end

        ---Records a dismissal that the interaction target must never call.
        ---@param self table
        function screen:dismiss()
            self.dismissals = self.dismissals + 1
        end

        local target = interaction_target.new_owned_screen(screen, {
            is_active=function(candidate) return candidate.active end,
            resolve_native_screen=function(candidate)
                assert.equals(screen, candidate)
                return native
            end,
        })

        assert.equals(screen, target:assert_current('input'))
        assert.equals(native, target:native_screen('input'))
        assert.equals('invalidated', target:invalidate())
        assert.equals(1, screen.invalidations)
        assert.is_true(target:cleanup())
        assert.is_false(target:cleanup())
        assert.equals(0, screen.dismissals)
        assert.has_error(function() target:assert_current('input') end,
            'input screen is no longer available')
    end)

    it('rejects inactive screens without resolving or invalidating them',
            function()
        local resolved = false
        local screen = {
            active=false,
            invalidate=function()
                error('inactive screen must not be invalidated')
            end,
        }
        local target = interaction_target.new_owned_screen(screen, {
            is_active=function(candidate) return candidate.active end,
            resolve_native_screen=function()
                resolved = true
            end,
        })

        assert.has_error(function() target:native_screen('mouse input') end,
            'mouse input screen is not currently active')
        assert.has_error(function() target:invalidate() end,
            'redraw screen is not currently active')
        assert.is_false(resolved)
    end)
end)

describe('borrowed native-screen interaction target', function()
    it('routes input and invalidation without dismissing the pinned screen',
            function()
        local current
        local invalidations = 0
        local screen = {
            dismissals=0,
            ---Records a forbidden native-screen dismissal.
            ---@param self table
            dismiss=function(self)
                self.dismissals = self.dismissals + 1
            end,
        }
        current = screen
        local target = interaction_target.new_borrowed_native(screen, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function()
                invalidations = invalidations + 1
                return 'invalidated'
            end,
        })

        assert.equals(screen, target:assert_current('input'))
        assert.equals(screen, target:native_screen('input'))
        assert.equals('invalidated', target:invalidate())
        assert.equals(1, invalidations)
        assert.is_true(target:cleanup())
        assert.is_false(target:cleanup())
        assert.equals(0, screen.dismissals)
        assert.has_error(function() target:native_screen('input') end,
            'input native screen is no longer available')
    end)

    it('rejects a screen transition before input or invalidation', function()
        local first = {}
        local current = first
        local invalidated = false
        local target = interaction_target.new_borrowed_native(first, {
            get_current_viewscreen=function() return current end,
            invalidate_screen=function()
                invalidated = true
            end,
        })
        current = {}

        local input_ok, input_failure =
            pcall(target.native_screen, target, 'input')
        assert.is_false(input_ok)
        assert.matches('DwarfSpec input rejected stale native%-screen ' ..
            'mount; pinned viewscreen is no longer current;',
            input_failure)
        assert.matches('captured_screen=table#%d+ current_screen=table#%d+',
            input_failure)
        local redraw_ok, redraw_failure = pcall(target.invalidate, target)
        assert.is_false(redraw_ok)
        assert.matches('DwarfSpec redraw rejected stale native%-screen ' ..
            'mount; pinned viewscreen is no longer current;',
            redraw_failure)
        assert.matches('captured_screen=table#%d+ current_screen=table#%d+',
            redraw_failure)
        assert.is_false(invalidated)
    end)
end)
