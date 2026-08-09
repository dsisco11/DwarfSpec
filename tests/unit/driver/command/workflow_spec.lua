-- Immutable state and commit-boundary tests for command workflows.

local Workflow = require('dwarfspec.driver.command.workflow')

describe('command workflow state', function()
    it('commits named immutable values and represents successful nil', function()
        local seen = {}
        local workflow = Workflow.new({steps={{name='first'}, {name='empty'}},
            result=function(state)
                assert.equals(7, state.outputs.first.value.value)
                assert.is_false(state.outputs.empty.has_value)
                assert.is_nil(state.outputs.empty.value)
                return {count=2}
            end}, {subject='unit-7'})
        local projected, state = workflow:execute(function(step, current)
            seen[#seen + 1] = current
            if step.name == 'first' then return {value=7} end
            return nil
        end)
        assert.equals(2, #seen)
        assert.is_nil(seen[1].outputs.first)
        assert.equals(7, seen[2].outputs.first.value.value)
        assert.equals(2, projected.count)
        assert.equals('unit-7', state.request.subject)
        assert.has_error(function() state.request.subject = 'changed' end)
        assert.has_error(function() state.outputs.first.value.value = 8 end)
        assert.has_error(function() projected.count = 3 end)
    end)

    it('commits no output when a step fails before returning', function()
        local workflow = Workflow.new({steps={{name='failed'}},
            result=function() error('projector must not run') end}, {})
        assert.has_error(function()
            workflow:execute(function() error('step failed') end)
        end, 'step failed')
        assert.is_nil(workflow:state().outputs.failed)
    end)

    it('rejects unbounded or behavioral step and projected values', function()
        local workflow = Workflow.new({steps={{name='behavior'}},
            result=function() return function() end end}, {})
        assert.has_error(function()
            workflow:execute(function() return function() end end)
        end)
        workflow = Workflow.new({steps={{name='plain'}},
            result=function() return function() end end}, {})
        assert.has_error(function()
            workflow:execute(function() return true end)
        end)
    end)

    it('rejects a yielding result projector', function()
        local workflow = Workflow.new({steps={{name='plain'}},
            result=function() coroutine.yield('not synchronous') end}, {})
        local succeeded, message = pcall(function()
            workflow:execute(function() return true end)
        end)
        assert.is_false(succeeded)
        assert.is_truthy(tostring(message):find(
            'projector must be synchronous', 1, true), tostring(message))
    end)
end)
