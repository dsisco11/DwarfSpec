local ClickRuntime = require('dwarfspec.driver.input.click_runtime')

describe('click runtime capability', function()
    it('combines target resolution, dispatch, and render observation', function()
        local subject = {control_path='root/button'}
        local target = {}
        local view = {}
        local runtime = ClickRuntime.new({resolver={
            resolve=function(_, value, operation)
                assert.equal(subject, value)
                assert.equal('click', operation)
                return view, target
            end}, dispatch=function(value, button)
                assert.equal(subject, value)
                assert.equal('right', button)
                return 7
            end})
        local context = {capture_render=function() return 6 end,
            observe_render=function(_, generation)
            return generation == 6
        end}

        assert.same({subject=subject, view=view, target=target,
            target_identity='root/button'}, runtime:resolve(subject))
        assert.equal(7, runtime:dispatch(subject, 'right'))
        assert.equal(6, runtime:capture_render(context))
        assert.is_true(runtime:observe_render(context, 6))
    end)

    it('rejects incomplete runtime construction', function()
        assert.has_error(function() ClickRuntime.new({}) end,
            'click runtime requires an interaction-target resolver')
    end)
end)
