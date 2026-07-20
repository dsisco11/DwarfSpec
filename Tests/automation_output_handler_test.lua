-- Unit contracts for Busted event collection in the in-process host.

local output_handler = assert(loadfile(
    'Tests/automation/support/output_handler.lua'))()

describe('automation Busted output collection', function()
    local original_base_loader
    local original_base_module

    before_each(function()
        original_base_loader = package.preload['busted.outputHandlers.base']
        original_base_module = package.loaded['busted.outputHandlers.base']
        package.preload['busted.outputHandlers.base'] = function()
            return function()
                local handler = {
                    successesCount=0,
                    failuresCount=0,
                    errorsCount=0,
                    pendingsCount=0,
                }

                ---Returns the stable fake Busted test name.
                ---@param element table
                ---@return string
                function handler.getFullName(element)
                    return element.name
                end

                ---Accepts the fake output subscription.
                function handler:subscribe()
                end

                ---Implements an inert Busted base event method.
                function handler.baseSuiteReset()
                end

                ---Implements an inert Busted base event method.
                function handler.baseSuiteStart()
                end

                ---Implements an inert Busted base event method.
                function handler.baseSuiteEnd()
                end

                ---Implements an inert Busted base event method.
                function handler.baseTestStart()
                end

                ---Implements an inert Busted base event method.
                function handler.baseTestEnd()
                end

                ---Implements an inert Busted base event method.
                function handler.baseTestFailure()
                end

                ---Implements an inert Busted base event method.
                function handler.baseTestError()
                end

                ---Implements an inert Busted base event method.
                function handler.baseError()
                end

                return handler
            end
        end
        package.loaded['busted.outputHandlers.base'] = nil
    end)

    after_each(function()
        package.preload['busted.outputHandlers.base'] = original_base_loader
        package.loaded['busted.outputHandlers.base'] = original_base_module
    end)

    it('records progress, classifications, and stable failure details',
            function()
        local run = {
            counts={successes=0, failures=0, errors=0, pending=0},
            totals={successes=0, failures=0, errors=0, pending=0},
            output_lines={},
            failure_details={},
            current_test=nil,
        }
        local handler = output_handler.new({}, run)
        local test = {name='suite records events'}

        handler.baseSuiteReset()
        handler.baseSuiteStart({}, 1, 1)
        handler.baseTestStart(test, {})
        handler.baseTestEnd(test, {}, 'success')
        handler.baseTestFailure(test, {}, 'expected failure', {
            traceback='trace text',
        })
        handler.baseTestError(test, {}, 'unexpected error', 'raw trace')
        handler.baseError({descriptor='file', name='fixture.lua'}, nil,
            'file error', 'file trace')
        handler.baseSuiteEnd({})

        assert.same({successes=1, failures=0, errors=1, pending=0},
            run.counts)
        assert.same({successes=1, failures=0, errors=1, pending=0},
            run.totals)
        assert.same('RUN 1/1', run.output_lines[1])
        assert.same('START suite records events', run.output_lines[2])
        assert.same('SUCCESS suite records events', run.output_lines[3])
        assert.equals(3, #run.failure_details)
        assert.same('failure', run.failure_details[1].kind)
        assert.same('trace text', run.failure_details[1].trace)
        assert.same('error', run.failure_details[2].kind)
        assert.same('raw trace', run.failure_details[2].trace)
        assert.same('error', run.failure_details[3].kind)
        assert.same('file error', run.failure_details[3].message)
        assert.same('RUN_END 1/1', run.output_lines[#run.output_lines])
    end)
end)
