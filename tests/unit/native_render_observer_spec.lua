-- Unit contracts for reversible native render observation.

local observer = assert(loadfile(
    'src/dwarfspec/native_render_observer.lua'))()

local function tracker_double()
    return {
        completions=0,
        failures={},
        completed=function(self)
            self.completions = self.completions + 1
            return self.completions
        end,
        failed=function(self, failure)
            table.insert(self.failures, failure)
        end,
    }
end

describe('DwarfSpec native render observer', function()
    it('forwards exact arguments, preserves returns, and completes pinned renders',
            function()
        local pinned = {}
        local received
        local overlay = {
            render_viewscreen_widgets=function(...)
                received = table.pack(...)
                return 'first', nil, 'third'
            end,
        }
        local original = overlay.render_viewscreen_widgets
        local tracker = tracker_double()
        local order = {}
        tracker.completed = function(self)
            table.insert(order, 'generation')
            self.completions = self.completions + 1
        end
        local restore = observer.install(
            overlay, pinned, tracker, nil, function()
                table.insert(order, 'completion')
            end)

        local first, second, third =
            overlay.render_viewscreen_widgets('viewscreen_name', pinned, nil)

        assert.equals(3, received.n)
        assert.equals('viewscreen_name', received[1])
        assert.equals(pinned, received[2])
        assert.is_nil(received[3])
        assert.equals('first', first)
        assert.is_nil(second)
        assert.equals('third', third)
        assert.same({'completion', 'generation'}, order)
        assert.equals(1, tracker.completions)
        assert.is_true(restore())
        assert.equals(original, overlay.render_viewscreen_widgets)
        assert.is_false(restore())
    end)

    it('ignores successful and failed dispatch for unrelated screens',
            function()
        local fail = false
        local overlay = {
            render_viewscreen_widgets=function()
                if fail then error('unrelated render exploded', 0) end
                return 'unrelated'
            end,
        }
        local tracker = tracker_double()
        observer.install(overlay, {}, tracker)

        assert.equals('unrelated',
            overlay.render_viewscreen_widgets('other', {}))
        fail = true
        assert.has_error(function()
            overlay.render_viewscreen_widgets('other', {})
        end, 'unrelated render exploded')
        assert.equals(0, tracker.completions)
        assert.same({}, tracker.failures)
    end)

    it('reports and preserves pinned dispatcher errors without completion',
            function()
        local pinned = {}
        local failure = {kind='render_failure'}
        local overlay = {
            render_viewscreen_widgets=function()
                error(failure, 0)
            end,
        }
        local tracker = tracker_double()
        observer.install(overlay, pinned, tracker)

        local ok, result = pcall(
            overlay.render_viewscreen_widgets, 'native', pinned)

        assert.is_false(ok)
        assert.equals(failure, result)
        assert.equals(0, tracker.completions)
        assert.same({failure}, tracker.failures)
    end)

    it('reports completion-observation failures without advancing', function()
        local pinned = {}
        local overlay = {render_viewscreen_widgets=function() end}
        local tracker = tracker_double()
        observer.install(overlay, pinned, tracker, function(failure)
            return 'native diagnostics: ' .. tostring(failure)
        end, function()
            error('refresh exploded', 0)
        end)

        local ok, failure = pcall(
            overlay.render_viewscreen_widgets, 'native', pinned)

        assert.is_false(ok)
        assert.matches('native diagnostics:', failure, 1, true)
        assert.matches('refresh exploded', failure, 1, true)
        assert.equals(0, tracker.completions)
        assert.equals(1, #tracker.failures)
    end)

    it('reports tracker completion failures through the tracker', function()
        local pinned = {}
        local overlay = {render_viewscreen_widgets=function() end}
        local tracker = tracker_double()
        tracker.completed = function()
            error('generation exploded', 0)
        end
        observer.install(overlay, pinned, tracker)

        local ok, failure = pcall(
            overlay.render_viewscreen_widgets, 'native', pinned)

        assert.is_false(ok)
        assert.matches('generation exploded', failure, 1, true)
        assert.equals(1, #tracker.failures)
    end)

    it('rejects unavailable dispatch before replacing anything', function()
        local overlay = {}

        assert.has_error(function()
            observer.install(overlay, {}, tracker_double())
        end, 'DFHack overlay dispatch is unavailable: ' ..
            'plugins.overlay.render_viewscreen_widgets is not a function')
        assert.is_nil(overlay.render_viewscreen_widgets)
    end)

    it('does not overwrite a conflicting dispatcher replacement', function()
        local overlay = {render_viewscreen_widgets=function() end}
        local original = overlay.render_viewscreen_widgets
        local restore = observer.install(overlay, {}, tracker_double())
        local replacement = function() end
        overlay.render_viewscreen_widgets = replacement

        assert.has_error(restore,
            'native render dispatcher changed before restoration')
        assert.equals(replacement, overlay.render_viewscreen_widgets)
        assert.not_equals(original, overlay.render_viewscreen_widgets)
    end)
end)
