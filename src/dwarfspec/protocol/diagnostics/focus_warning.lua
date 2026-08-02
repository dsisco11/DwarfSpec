-- Stable external formatting for validated base-screen focus warnings.

local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local focus = require('dwarfspec.protocol.diagnostics.focus')

local M = {}

local comparisons = {
    [EComparison.SAME]='same',
    [EComparison.CHANGED]='changed',
    [EComparison.UNAVAILABLE]='unavailable',
}

---Returns text safe for one retained or terminal output line.
---@param value string
---@return string
local function line_text(value)
    return value:gsub('[\r\n\t]', ' ')
end

---Formats one validated change diagnostic as a stable warning line.
---@param diagnostic table
---@return string
function M.format_warning(diagnostic)
    focus.validate(diagnostic)
    assert(diagnostic.kind == focus.CHANGE_KIND,
        'only focus change diagnostics can be formatted as warnings')
    local content = diagnostic.content
    local subject
    if content.scope == 'example' then
        subject = ('example %s in %s'):format(
            line_text(content.example_name or '<setup>'),
            line_text(content.suite_name))
    else
        subject = 'suite ' .. line_text(content.suite_name)
    end
    return ('WARNING base-screen focus changed after %s ' ..
        '(repeat=%d attribution=%s screen=%s focus=%s complete=%s)')
        :format(subject, content.repeat_index, content.attribution,
            comparisons[content.screen_comparison],
            comparisons[content.focus_comparison],
            tostring(content.details_complete))
end

return M
