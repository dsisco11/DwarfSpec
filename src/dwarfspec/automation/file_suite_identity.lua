-- DwarfSpec-owned identity for one executed Busted file suite.

---@class DwarfSpecFileSuiteIdentity
---@field suite_id string
---@field suite_name string
---@field source_identity string
---@field repeat_index integer
---@field repeat_count integer
local FileSuiteIdentity = {}
FileSuiteIdentity.__index = FileSuiteIdentity

---Returns whether a value is an integer.
---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number' and value % 1 == 0
end

---Creates one validated file-suite identity.
---@param fields DwarfSpecFileSuiteIdentity
---@return DwarfSpecFileSuiteIdentity
function FileSuiteIdentity.new(fields)
    assert(type(fields) == 'table',
        'file-suite identity fields must be a table')
    assert(type(fields.suite_id) == 'string' and fields.suite_id ~= '',
        'file-suite identity suite_id must be a nonempty string')
    assert(type(fields.suite_name) == 'string' and fields.suite_name ~= '',
        'file-suite identity suite_name must be a nonempty string')
    assert(type(fields.source_identity) == 'string' and
        fields.source_identity ~= '',
        'file-suite identity source_identity must be a nonempty string')
    assert(is_integer(fields.repeat_index) and fields.repeat_index >= 1,
        'file-suite identity repeat_index must be a positive integer')
    assert(is_integer(fields.repeat_count) and fields.repeat_count >= 1,
        'file-suite identity repeat_count must be a positive integer')
    return setmetatable({
        suite_id=fields.suite_id,
        suite_name=fields.suite_name,
        source_identity=fields.source_identity,
        repeat_index=fields.repeat_index,
        repeat_count=fields.repeat_count,
    }, FileSuiteIdentity)
end

---Returns an independently mutable copy of this identity.
---@return DwarfSpecFileSuiteIdentity
function FileSuiteIdentity:copy()
    return FileSuiteIdentity.new(self)
end

return FileSuiteIdentity
