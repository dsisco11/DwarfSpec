-- Unit contracts for standard one-line DwarfSpec diagnostic formats.

local formatter = require('dwarfspec.controller.reporting.diagnostic_formatter')
local ErrorFormat = require('dwarfspec.protocol.configuration.error_formats')

local ESC = string.char(27)

---Creates one complete structured problem with optional field overrides.
---@param overrides table|nil
---@return table
local function problem(overrides)
    local value = {
        kind='failure',
        name='suite example',
        message='expected true',
        source_identity='tests/example.ds.lua',
        line=12,
        column=4,
    }
    for key, replacement in pairs(overrides or {}) do
        value[key] = replacement
    end
    return value
end

---Counts physical lines in one rendered diagnostic.
---@param value string
---@return integer
local function physical_line_count(value)
    local _, line_feeds = value:gsub('\n', '')
    local _, carriage_returns = value:gsub('\r', '')
    return line_feeds + carriage_returns + 1
end

describe('standard diagnostic formatter', function()
    it('renders the canonical MSBuild assertion-failure shape', function()
        assert.equals(
            'D:\\project\\tests\\example.ds.lua(12,4): error DS1001: ' ..
                'suite example: expected true',
            formatter.format(ErrorFormat.MSBUILD, 'D:\\project', problem()))
    end)

    it('renders the canonical GCC and Clang shape with an error severity',
            function()
        assert.equals(
            'D:/project/tests/example.ds.lua:12:4: error: ' ..
                'suite example: expected true',
            formatter.format(ErrorFormat.GCC, 'D:\\project', problem()))
    end)

    it('renders the canonical project-relative ESLint Compact shape',
            function()
        assert.equals(
            'tests/example.ds.lua: line 12, col 4, Error - ' ..
                'suite example: expected true (dwarfspec)',
            formatter.format(ErrorFormat.ESLINT, '/project', problem()))
    end)

    it('maps test, hook, and file errors to the stable MSBuild code',
            function()
        for _, name in ipairs({'suite error', 'before_each', 'fixture.lua'}) do
            assert.equals(
                '/project/tests/error.ds.lua(9,2): error DS1002: ' ..
                    name .. ': unexpected nil',
                formatter.format(ErrorFormat.MSBUILD, '/project', problem({
                    kind='error',
                    name=name,
                    message='unexpected nil',
                    source_identity='tests/error.ds.lua',
                    line=9,
                    column=2,
                })))
        end
    end)

    it('defaults a missing column to one for matchable locations',
            function()
        local missing_column = problem({line=27})
        missing_column.column = nil
        assert.equals(
            '/project root/tests/example.ds.lua:27:1: error: ' ..
                'suite example: expected true',
            formatter.format(
                ErrorFormat.GCC, '/project root', missing_column))
    end)

    it('normalizes both path styles for each selected grammar', function()
        local mixed = problem({
            source_identity='tests\\nested  path/example.ds.lua',
        })
        assert.equals(
            'C:\\Project  Root\\tests\\nested  path\\example.ds.lua(12,4): ' ..
                'error DS1001: suite example: expected true',
            formatter.format(
                ErrorFormat.MSBUILD, 'C:/Project  Root', mixed))
        assert.equals(
            'C:/Project  Root/tests/nested  path/example.ds.lua:12:4: ' ..
                'error: ' ..
                'suite example: expected true',
            formatter.format(ErrorFormat.GCC, 'C:\\Project  Root', mixed))
        assert.equals(
            'tests/nested  path/example.ds.lua: line 12, col 4, Error - ' ..
                'suite example: expected true (dwarfspec)',
            formatter.format(ErrorFormat.ESLINT, 'C:\\Project  Root', mixed))
    end)

    it('sanitizes controls and ANSI while preserving punctuation and UTF-8',
            function()
        local original = problem({
            name='suite:  café (日本語)',
            message='expected\r\n\ttrue\v' ..
                ESC .. '[31mred' .. ESC .. '[0m:  (value)' ..
                ESC .. ']0;hidden' .. string.char(7) .. '\127',
        })
        local before = {}
        for key, value in pairs(original) do before[key] = value end
        local rendered = formatter.format(
            ErrorFormat.GCC, '/project', original)
        assert.equals(
            '/project/tests/example.ds.lua:12:4: error: ' ..
                'suite:  café (日本語): expected true red:  (value)',
            rendered)
        assert.equals(1, physical_line_count(rendered))
        assert.same(before, original)
    end)

    it('produces one physical line for every matchable format', function()
        local unsafe = problem({
            source_identity='tests/control' .. string.char(9) .. '.ds.lua',
            name='suite\r\nname',
            message='first\nsecond',
        })
        for _, error_format in pairs(ErrorFormat) do
            assert.equals(1, physical_line_count(
                formatter.format(error_format, '/project', unsafe)))
        end
    end)

    it('uses a sanitized human-readable fallback without inventing a line',
            function()
        local locationless = problem({
            kind='error',
            name='unresolved fixture',
            message='could not load\r\nnext line',
        })
        locationless.source_identity = nil
        locationless.line = nil
        locationless.column = nil
        assert.equals(
            'ERROR unresolved fixture: could not load next line',
            formatter.format(
                ErrorFormat.MSBUILD, '/project', locationless))
        local missing_line = problem()
        missing_line.line = nil
        assert.equals(
            'FAILURE suite example: expected true',
            formatter.format(
                ErrorFormat.ESLINT, '/project', missing_line))
    end)
end)
