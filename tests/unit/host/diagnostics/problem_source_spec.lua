-- Unit contracts for presentation-neutral Busted problem source extraction.

local problem_source = require('dwarfspec.host.diagnostics.problem_source')
local fixtures = assert(loadfile(
    'tests/support/problem_fixtures.lua'))()

describe('automation problem source extraction', function()
    it('honors the locked source precedence fixtures', function()
        for name, fixture in pairs(fixtures.cases) do
            local actual = problem_source.extract(
                fixture.project_root,
                fixture.selected_source_identity,
                fixture.element,
                fixture.trace)
            if fixture.expected_source == nil then
                assert.is_nil(actual, name)
            else
                assert.same({
                    source_identity=fixture.expected_source.identity,
                    line=fixture.expected_source.line,
                    column=fixture.expected_source.column,
                }, actual, name)
            end
        end
    end)

    it('normalizes mixed separators and retains structured columns',
            function()
        assert.same({
            source_identity='tests/nested/example.ds.lua',
            line=19,
            column=7,
        }, problem_source.extract(
            'D:\\Project Root',
            'tests/nested/example.ds.lua',
            {source='tests/nested/example.ds.lua'},
            {
                source='@D:/Project Root\\tests/nested\\example.ds.lua',
                currentline=19,
                currentcolumn=7,
            }))
    end)

    it('uses the element definition when trace data has no location',
            function()
        assert.same({
            source_identity='tests/element fallback.ds.lua',
            line=31,
        }, problem_source.extract(
            '/workspace/project',
            'tests/element fallback.ds.lua',
            {
                trace={
                    source='@/workspace/project/tests/' ..
                        'element fallback.ds.lua',
                    currentline=31,
                },
            },
            {}))
    end)

    it('uses structured short source when the primary source is ineligible',
            function()
        assert.same({
            source_identity='tests/short-source.ds.lua',
            line=6,
        }, problem_source.extract(
            '/workspace/project',
            'tests/short-source.ds.lua',
            {source='tests/short-source.ds.lua'},
            {
                source='@/usr/share/lua/5.4/busted/core.lua',
                short_src='/workspace/project/tests/short-source.ds.lua',
                currentline=6,
            }))
    end)

    it('prefers a selected test frame over internal rendered frames',
            function()
        local trace = 'C:\\Project\\src\\dwarfspec\\automation\\host.lua:' ..
            '500: internal\n' ..
            'C:/Project/tests/selected test.ds.lua:42: assertion'
        assert.same({
            source_identity='tests/selected test.ds.lua',
            line=42,
        }, problem_source.extract(
            'C:\\Project',
            'tests\\selected test.ds.lua',
            {source='tests\\selected test.ds.lua'},
            trace))
    end)

    it('rejects external, internal, escaping, and locationless sources',
            function()
        for _, sample in ipairs({
                {
                    element={},
                    trace={source='@/outside/test.ds.lua', currentline=3},
                },
                {
                    element={},
                    trace={
                        source='@/project/src/dwarfspec/controller/execution/runner.lua',
                        currentline=4,
                    },
                },
                {
                    element={source='../escape.ds.lua', currentline=5},
                    trace='stack traceback:\n\t[C]: in ?',
                },
            }) do
            assert.is_nil(problem_source.extract(
                '/project', nil, sample.element, sample.trace))
        end
    end)

    it('bounds rendered trace parsing', function()
        local lines = {}
        for index = 1, 128 do
            lines[index] = 'stack frame without a location'
        end
        lines[129] = '/project/tests/too-late.ds.lua:9: error'
        assert.is_nil(problem_source.extract(
            '/project', nil, {}, table.concat(lines, '\n')))
    end)
end)
