-- Direct contracts for mounted command execution.

local commands = require(
    'dwarfspec.driver.mount.mount_command_execution')

---Creates one command context with controllable render behavior.
---@return table, table, table
local function make_context()
    local events = {}
    local tracker = {
        capture=function() return 7 end,
        wait_after=function(_, generation, label)
            table.insert(events, {'wait', generation, label})
            return true
        end,
    }
    local mount = {
        id=4,
        category='widget',
        alive=true,
        root={name='root'},
        host_screen={},
        options={viewport={}},
        adapter={
            viewport=function(_, _, viewport)
                return viewport.width, viewport.height
            end,
        },
        render_tracker=tracker,
    }
    local context = {
        current=mount,
        boundary={
            normalize_viewport=function(_, value) return value end,
        },
        subject_commands={},
        refresh_views=function(_, value)
            table.insert(events, {'refresh', value.id})
        end,
        new_subject=function(_, view, path)
            return {view=view, path=path}
        end,
        resolve_subject=function() return true end,
    }
    context.render = {
        capture=function(_, value)
            return value.render_tracker:capture()
        end,
        wait_after=function(_, value, captured, label)
            return value.render_tracker:wait_after(captured, label)
        end,
    }
    return commands.new(context), mount, events
end

describe('mount command execution', function()
    it('preserves current-mount guards and root selection', function()
        local context, mount = make_context()
        assert.same({view=mount.root, path='<root>'}, context:root())
        mount.alive = false
        assert.has_error(function() context:root() end,
            'DwarfSpec root requires a current mount; call ' ..
            'ds.mount(component, options) or ds.mountNativeScreen() first')
    end)

    it('preserves command arguments and multiple returns', function()
        local context, mount = make_context()
        local selected = {mount_id=mount.id, control_path='button'}
        context.subject_commands.click = function(subject, first, second)
            assert.equals(selected, subject)
            return first + second, 'done'
        end
        local total, state =
            context:invoke_subject_command(selected, 'click', 2, 3)
        assert.equals(5, total)
        assert.equals('done', state)
        assert.is_nil(mount.command_subject)
    end)

    it('supports synchronous mutations without a render wait', function()
        local context, _, events = make_context()
        assert.equals('changed', context:mutate('sync', function()
            return 'changed'
        end, {wait_for_render=false}))
        assert.same({{'refresh', 4}}, events)
    end)

    it('waits for render completion before refreshing', function()
        local context, _, events = make_context()
        context:mutate('click', function() return true end)
        assert.same({
            {'wait', 7, 'click render'},
            {'refresh', 4},
        }, events)
    end)

    it('preserves enriched action and render-failure diagnostics', function()
        local context, mount = make_context()
        context.failure_reporter = function(_, operation, failure)
            return operation .. ': ' .. failure
        end
        local action_ok, action_failure = pcall(function()
            context:mutate('activate', function() error('action failed', 0) end)
        end)
        assert.is_false(action_ok)
        assert.matches('activate: action failed', action_failure, 1, true)
        mount.render_tracker.wait_after = function()
            error('render failed before completion', 0)
        end
        local render_ok, render_failure = pcall(function()
            context:mutate('activate', function() return true end)
        end)
        assert.is_false(render_ok)
        assert.matches(
            'activate: render failed before completion',
            render_failure, 1, true)
    end)

    it('preserves render-timeout diagnostics distinctly', function()
        local context, mount = make_context()
        context.failure_reporter = function(_, operation, failure)
            return operation .. ': ' .. failure
        end
        mount.render_tracker.wait_after = function()
            error('render timeout after 40 frames', 0)
        end
        local ok, failure = pcall(function()
            context:mutate('activate', function() return true end)
        end)
        assert.is_false(ok)
        assert.matches(
            'activate: render timeout after 40 frames',
            failure, 1, true)
    end)

    it('updates the viewport through the mounted adapter', function()
        local context, mount = make_context()
        local width, height = context:viewport(80, 25)
        assert.equals(80, width)
        assert.equals(25, height)
        assert.same({width=80, height=25}, mount.options.viewport)
    end)
end)
