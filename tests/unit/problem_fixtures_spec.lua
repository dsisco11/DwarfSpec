-- Baseline contracts for future CLI problem-location and formatting work.

local fixtures = assert(loadfile(
    'tests/support/problem_fixtures.lua'))()
local report = require('dwarfspec.report')
local EventType = require('dwarfspec.protocol.enums.event_types')

---Returns whether a string contains a Windows or Unix-like absolute path.
---@param value string
---@return boolean
local function has_absolute_path(value)
    return value:match('^%a:[/\\]') ~= nil or value:sub(1, 1) == '/'
end

describe('CLI problem baseline fixtures', function()
    it('covers representative callbacks and location availability', function()
        local cases = fixtures.cases

        assert.equals('baseTestFailure',
            cases.assertion_failure.callback)
        assert.equals('failure', cases.assertion_failure.kind)
        assert.equals('baseTestError', cases.test_error.callback)
        assert.equals('error', cases.test_error.kind)
        assert.equals('baseError', cases.hook_error.callback)
        assert.equals('before_each',
            cases.hook_error.element.descriptor)
        assert.equals('baseError',
            cases.locationless_file_error.callback)
        assert.equals('file',
            cases.locationless_file_error.element.descriptor)
        assert.is_nil(cases.locationless_file_error.expected_source)
    end)

    it('characterizes table and string traces for every callback form',
            function()
        local callbacks = {}
        for _, fixture in pairs(fixtures.cases) do
            callbacks[fixture.callback] = true
            assert.equals('table',
                type(fixture.trace_forms.table_value))
            assert.equals('string',
                type(fixture.trace_forms.string_value))
        end

        assert.same({
            baseTestFailure=true,
            baseTestError=true,
            baseError=true,
        }, callbacks)
    end)

    it('covers required paths, missing columns, and unsafe display text',
            function()
        local assertion = fixtures.cases.assertion_failure
        local test_error = fixtures.cases.test_error
        local hook = fixtures.cases.hook_error

        assert.is_true(has_absolute_path(assertion.project_root))
        assert.is_true(has_absolute_path(test_error.project_root))
        assert.matches('\\', assertion.project_root, 1, true)
        assert.matches('/', test_error.project_root, 1, true)
        assert.matches(' ', assertion.project_root, 1, true)
        assert.matches(' ', test_error.project_root, 1, true)
        assert.is_nil(assertion.expected_source.column)
        assert.matches('\r\n', assertion.message, 1, true)
        assert.matches('\t', assertion.message, 1, true)
        assert.matches(string.char(27) .. '[31m',
            assertion.message, 1, true)
        assert.matches('\v', hook.message, 1, true)
    end)

    it('records the current human-readable problem output exactly',
            function()
        for _, fixture in pairs(fixtures.cases) do
            local lines = report.format_events({
                {
                    type=EventType.PROBLEM_RECORDED,
                    payload={
                        kind=fixture.kind,
                        name=fixture.element.name,
                        message=fixture.message,
                        trace=fixture.trace,
                    },
                },
            })

            assert.same({fixture.current_human_output}, lines)
        end
    end)

    it('defines source precedence before location extraction begins',
            function()
        assert.same({
            'Use structured trace source, short_src, and currentline when ' ..
                'they identify a trustworthy project-owned source.',
            'Reject DwarfSpec, Busted, Lua, and cleanup implementation ' ..
                'frames before considering rendered trace text.',
            'Use a trustworthy selected-test-file frame from a rendered ' ..
                'string trace when no eligible structured trace location ' ..
                'exists.',
            'Use the Busted element source for the selected test file when ' ..
                'trace data has no more precise eligible location.',
            'Leave source, line, and column absent when no trustworthy ' ..
                'project-owned location remains.',
        }, fixtures.source_precedence)
    end)
end)
