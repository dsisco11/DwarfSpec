-- Baseline Busted callback and problem-output fixtures for CLI diagnostics.

local ESC = string.char(27)

---@class tests.ProblemFixture
---@field callback string
---@field kind string
---@field project_root string
---@field selected_source_identity string|nil
---@field element table
---@field message string
---@field trace table|string
---@field trace_forms table
---@field expected_source table|nil
---@field current_human_output string

---@class tests.ProblemFixtureSet
---@field busted_version string
---@field current_human_shape string
---@field source_precedence string[]
---@field cases table<string, tests.ProblemFixture>
local fixtures = {
    busted_version='2.3.0',
    current_human_shape='<KIND> <full test or hook name>: <message>',
    source_precedence={
        'Use structured trace source, short_src, and currentline when they ' ..
            'identify a trustworthy project-owned source.',
        'Reject DwarfSpec, Busted, Lua, and cleanup implementation frames ' ..
            'before considering rendered trace text.',
        'Use a trustworthy selected-test-file frame from a rendered string ' ..
            'trace when no eligible structured trace location exists.',
        'Use the Busted element source for the selected test file when trace ' ..
            'data has no more precise eligible location.',
        'Leave source, line, and column absent when no trustworthy ' ..
            'project-owned location remains.',
    },
    cases={},
}

fixtures.cases.assertion_failure = {
    callback='baseTestFailure',
    kind='failure',
    project_root='D:\\Projects\\Dwarf Spec Fixture',
    selected_source_identity='tests\\assertion_failure.ds.lua',
    element={
        descriptor='it',
        name='suite assertion failure',
        source='tests\\assertion_failure.ds.lua',
        short_src='tests\\assertion_failure.ds.lua',
    },
    message='expected true\r\n\tbut got false ' ..
        ESC .. '[31mred' .. ESC .. '[0m',
    trace={
        source='@D:\\Projects\\Dwarf Spec Fixture\\tests\\' ..
            'assertion_failure.ds.lua',
        short_src='D:\\Projects\\Dwarf Spec Fixture\\tests\\' ..
            'assertion_failure.ds.lua',
        currentline=12,
        traceback='stack traceback:\n\tD:\\Projects\\Dwarf Spec Fixture\\' ..
            'tests\\assertion_failure.ds.lua:12: in function <...>',
    },
    trace_forms={
        table_value={
            source='@D:\\Projects\\Dwarf Spec Fixture\\tests\\' ..
                'assertion_failure.ds.lua',
            short_src='D:\\Projects\\Dwarf Spec Fixture\\tests\\' ..
                'assertion_failure.ds.lua',
            currentline=12,
            traceback='stack traceback:\n\tD:\\Projects\\Dwarf Spec Fixture\\' ..
                'tests\\assertion_failure.ds.lua:12: in function <...>',
        },
        string_value='D:\\Projects\\Dwarf Spec Fixture\\tests\\' ..
            'assertion_failure.ds.lua:12: expected true',
    },
    expected_source={
        identity='tests/assertion_failure.ds.lua',
        line=12,
        column=nil,
        origin='structured_trace',
    },
    current_human_output='FAILURE suite assertion failure: expected true\r\n' ..
        '\tbut got false ' .. ESC .. '[31mred' .. ESC .. '[0m',
}

fixtures.cases.test_error = {
    callback='baseTestError',
    kind='error',
    project_root='/home/example/Dwarf Spec Fixture',
    selected_source_identity='tests/test_error.ds.lua',
    element={
        descriptor='it',
        name='suite test error',
        source='tests/test_error.ds.lua',
        short_src='tests/test_error.ds.lua',
    },
    message='unexpected nil: café',
    trace='/home/example/Dwarf Spec Fixture/tests/test_error.ds.lua:27: ' ..
        'attempt to index a nil value\nstack traceback:',
    trace_forms={
        table_value={
            source='@/home/example/Dwarf Spec Fixture/tests/test_error.ds.lua',
            short_src='/home/example/Dwarf Spec Fixture/tests/' ..
                'test_error.ds.lua',
            currentline=27,
            traceback='stack traceback:\n\t/home/example/Dwarf Spec Fixture/' ..
                'tests/test_error.ds.lua:27: in function <...>',
        },
        string_value='/home/example/Dwarf Spec Fixture/tests/' ..
            'test_error.ds.lua:27: attempt to index a nil value\n' ..
            'stack traceback:',
    },
    expected_source={
        identity='tests/test_error.ds.lua',
        line=27,
        column=nil,
        origin='string_trace',
    },
    current_human_output='ERROR suite test error: unexpected nil: café',
}

fixtures.cases.hook_error = {
    callback='baseError',
    kind='error',
    project_root='/home/example/Dwarf Spec Fixture',
    selected_source_identity='tests/hook_error.ds.lua',
    element={
        descriptor='before_each',
        name='before_each',
        source='tests/hook_error.ds.lua',
        short_src='tests/hook_error.ds.lua',
    },
    message='hook failed\vafter setup',
    trace={
        source='@/usr/share/lua/5.4/busted/core.lua',
        short_src='/usr/share/lua/5.4/busted/core.lua',
        currentline=180,
        traceback='stack traceback:\n\t/home/example/Dwarf Spec Fixture/' ..
            'tests/hook_error.ds.lua:8: in function <...>\n\t' ..
            '/usr/share/lua/5.4/busted/core.lua:180: in function <...>',
    },
    trace_forms={
        table_value={
            source='@/usr/share/lua/5.4/busted/core.lua',
            short_src='/usr/share/lua/5.4/busted/core.lua',
            currentline=180,
            traceback='stack traceback:\n\t/home/example/Dwarf Spec Fixture/' ..
                'tests/hook_error.ds.lua:8: in function <...>',
        },
        string_value='stack traceback:\n\t/home/example/' ..
            'Dwarf Spec Fixture/tests/hook_error.ds.lua:8: in function <...>',
    },
    expected_source={
        identity='tests/hook_error.ds.lua',
        line=8,
        column=nil,
        origin='string_trace_after_internal_rejection',
    },
    current_human_output='ERROR before_each: hook failed\vafter setup',
}

fixtures.cases.locationless_file_error = {
    callback='baseError',
    kind='error',
    project_root='D:\\Projects\\Dwarf Spec Fixture',
    selected_source_identity=nil,
    element={
        descriptor='file',
        name='unresolved fixture',
    },
    message='file could not be loaded',
    trace='stack traceback:\n\t[C]: in ?',
    trace_forms={
        table_value={},
        string_value='stack traceback:\n\t[C]: in ?',
    },
    expected_source=nil,
    current_human_output='ERROR unresolved fixture: file could not be loaded',
}

return fixtures
