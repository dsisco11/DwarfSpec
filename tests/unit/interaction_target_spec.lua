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
