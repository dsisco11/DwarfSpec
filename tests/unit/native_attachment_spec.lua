-- Unit contracts for validated non-owning native viewscreen attachment.

local interaction_target = require('dwarfspec.interaction_target')
local native_attachment = require('dwarfspec.native_attachment')
local native_widget_adapter = require('dwarfspec.native_widget_adapter')

describe('DwarfSpec native viewscreen attachment', function()
    local current
    local native
    local attachment
    local target_factory_calls
    local source_factory_calls
    local invalidations

    before_each(function()
        target_factory_calls = 0
        source_factory_calls = 0
        invalidations = 0
        local root = {kind='widget-root'}
        current = {
            widgets=root,
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }
        native = current
        attachment = native_attachment.new({
            get_native_viewscreen=function() return native end,
            is_widget_root=function(candidate)
                return type(candidate) == 'table' and
                    candidate.kind == 'widget-root'
            end,
            interaction_target_factory=function(screen)
                target_factory_calls = target_factory_calls + 1
                return interaction_target.new_borrowed_native(screen, {
                    get_current_viewscreen=function() return current end,
                    invalidate_screen=function()
                        invalidations = invalidations + 1
                    end,
                })
            end,
            subject_source_factory=function(root_value, target)
                source_factory_calls = source_factory_calls + 1
                return native_widget_adapter.new_source(
                    root_value, target, {
                        get_widget=function() return nil end,
                        get_children=function() return {} end,
                        is_container=function() return true end,
                    })
            end,
        })
    end)

    it('pins the exact current native screen and widget root', function()
        local result = attachment:attach()

        assert.equals(current, result.pinned_screen)
        assert.equals(current.widgets, result.root)
        assert.equals(current.widgets,
            result.subject_source.adapter:root())
        assert.equals(current,
            result.interaction_target:input_screen('input'))
        assert.equals(1, target_factory_calls)
        assert.equals(1, source_factory_calls)
        assert.same({
            show_calls=0,
            dismiss_calls=0,
            resize_calls=0,
            replace_calls=0,
            navigation_calls=0,
        }, {
            show_calls=current.show_calls,
            dismiss_calls=current.dismiss_calls,
            resize_calls=current.resize_calls,
            replace_calls=current.replace_calls,
            navigation_calls=current.navigation_calls,
        })
    end)

    it('attaches without a current input viewscreen',
            function()
        current = nil

        local result = attachment:attach()

        assert.equals(native, result.pinned_screen)
        assert.equals(native.widgets, result.root)
        assert.has_error(
            function() result.interaction_target:input_screen('input') end,
            'DwarfSpec input requires a current input viewscreen')
        assert.equals(1, target_factory_calls)
        assert.equals(1, source_factory_calls)
    end)

    it('rejects a missing native DF viewscreen before allocating resources',
            function()
        native = nil

        assert.has_error(function() attachment:attach() end,
            'DwarfSpec native-screen mount requires a native DF viewscreen')
        assert.equals(0, target_factory_calls)
        assert.equals(0, source_factory_calls)
    end)

    it('borrows the native root beneath a focused DFHack Lua screen',
            function()
        local native_screen = {
            widgets={kind='widget-root'},
        }
        native = native_screen
        local before_current = current

        local result = attachment:attach()

        assert.equals(native_screen, result.pinned_screen)
        assert.equals(native_screen.widgets, result.root)
        assert.equals(before_current,
            result.interaction_target:input_screen('input'))
        assert.equals(before_current, current)
        assert.equals(native_screen, native)
        assert.equals(1, target_factory_calls)
        assert.equals(1, source_factory_calls)
    end)

    it('rejects a missing or invalid widget root before allocating resources',
            function()
        native.widgets = nil

        assert.has_error(function() attachment:attach() end,
            'DwarfSpec native-screen mount requires the native DF viewscreen ' ..
                'to expose a valid widgets container')
        assert.equals(0, target_factory_calls)
        assert.equals(0, source_factory_calls)
    end)

    it('releases a partial target when source construction fails', function()
        local cleaned = 0
        attachment = native_attachment.new({
            get_native_viewscreen=function() return native end,
            is_widget_root=function() return true end,
            interaction_target_factory=function()
                return {
                    cleanup=function()
                        cleaned = cleaned + 1
                    end,
                }
            end,
            subject_source_factory=function()
                error('source construction exploded')
            end,
        })

        local ok, failure = pcall(attachment.attach, attachment)

        assert.is_false(ok)
        assert.matches('source construction exploded', failure, 1, true)
        assert.equals(1, cleaned)
    end)

    it('preserves source failure when partial target cleanup also fails',
            function()
        attachment = native_attachment.new({
            get_native_viewscreen=function() return native end,
            is_widget_root=function(root)
                return root and root.kind == 'widget-root'
            end,
            interaction_target_factory=function()
                return {
                    cleanup=function()
                        error('target cleanup exploded', 0)
                    end,
                }
            end,
            subject_source_factory=function()
                error('source construction exploded', 0)
            end,
        })

        local ok, failure = pcall(attachment.attach, attachment)

        assert.is_false(ok)
        assert.matches('source construction exploded', failure, 1, true)
        assert.matches('partial target cleanup failed:', failure, 1, true)
        assert.matches('target cleanup exploded', failure, 1, true)
    end)

    it('retains the root while input follows a screen transition',
            function()
        local result = attachment:attach()
        local next_screen = {
            widgets={kind='widget-root'},
        }
        current = next_screen

        assert.equals(native.widgets,
            result.subject_source.adapter:root())
        assert.equals(native,
            result.interaction_target:native_screen('focus inspection'))
        assert.equals(next_screen,
            result.interaction_target:input_screen('input'))
        result.interaction_target:invalidate()
        assert.equals(1, invalidations)
    end)
end)
