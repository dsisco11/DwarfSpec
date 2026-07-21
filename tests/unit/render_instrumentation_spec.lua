-- Unit contracts for reversible render interception.

local instrumentation = assert(loadfile(
    'src/dwarfspec/render_instrumentation.lua'))()

---Creates a tracker double that records render outcomes.
---@return table
local function tracker_double()
    return {
        completions=0,
        failures={},
        completed=function(self)
            self.completions = self.completions + 1
        end,
        failed=function(self, message)
            table.insert(self.failures, message)
        end,
    }
end

describe('DwarfSpec render instrumentation', function()
    it('preserves inherited behavior and restores instance lookup', function()
        local parent = {
            onRender=function(self, value)
                self.rendered = value
                return 'first', nil, 'third'
            end,
        }
        local target = setmetatable({}, {__index=parent})
        local tracker = tracker_double()
        local restore = instrumentation.install(target, tracker)

        local first, second, third = target:onRender('value')

        assert.equals('first', first)
        assert.is_nil(second)
        assert.equals('third', third)
        assert.equals('value', target.rendered)
        assert.equals(1, tracker.completions)
        assert.is_true(restore())
        assert.is_nil(rawget(target, 'onRender'))
        assert.equals('first', target:onRender('after restore'))
        assert.is_false(restore())
    end)

    it('restores an existing instance override exactly', function()
        local original = function() return 'original' end
        local target = {onRender=original}
        local restore = instrumentation.install(target, tracker_double())

        restore()

        assert.equals(original, rawget(target, 'onRender'))
    end)

    it('retains the original failure and does not record completion', function()
        local target = {
            onRender=function()
                error('original render exploded', 0)
            end,
        }
        local tracker = tracker_double()
        instrumentation.install(target, tracker, function(message)
            return 'mount diagnostics: ' .. message
        end)

        local ok, message = pcall(target.onRender, target)

        assert.is_false(ok)
        assert.matches('mount diagnostics:', message, 1, true)
        assert.matches('original render exploded', message, 1, true)
        assert.equals(0, tracker.completions)
        assert.equals(1, #tracker.failures)
        assert.matches('original render exploded', tracker.failures[1], 1,
            true)
    end)

    it('refuses to overwrite an unrelated replacement on restore', function()
        local target = {onRender=function() end}
        local restore = instrumentation.install(target, tracker_double())
        rawset(target, 'onRender', function() end)

        assert.has_error(restore,
            'instrumented onRender changed before restoration')
    end)

    it('runs completion work before publishing the generation', function()
        local order = {}
        local tracker = tracker_double()
        tracker.completed = function(self)
            table.insert(order, 'generation')
            self.completions = self.completions + 1
        end
        local target = {onRender=function()
            table.insert(order, 'render')
        end}
        instrumentation.install(target, tracker, nil, function()
            table.insert(order, 'completion')
        end)

        target:onRender()

        assert.same({'render', 'completion', 'generation'}, order)
    end)

    it('does not publish a generation when completion work fails', function()
        local tracker = tracker_double()
        local target = {onRender=function() end}
        instrumentation.install(target, tracker, nil, function()
            error('completion indexing exploded', 0)
        end)

        local ok, message = pcall(target.onRender, target)

        assert.is_false(ok)
        assert.matches('completion indexing exploded', message, 1, true)
        assert.equals(0, tracker.completions)
        assert.equals(1, #tracker.failures)
    end)
end)
