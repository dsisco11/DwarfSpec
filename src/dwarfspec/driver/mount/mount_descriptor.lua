-- Tagged TestBed-backed component descriptor validation and resolution.

local M = {}

---Validates one tagged module or script descriptor.
---@param value any
---@return table
function M.validate(value)
    assert(type(value) == 'table', 'DwarfSpec mount descriptor must be a table')
    for key in pairs(value) do
        assert(key == 'kind' or key == 'name' or key == 'export',
            'DwarfSpec mount descriptor has an unknown field: ' .. tostring(key))
    end
    assert(value.kind == 'module' or value.kind == 'script',
        'DwarfSpec mount descriptor kind must be "module" or "script"')
    assert(type(value.name) == 'string',
        'DwarfSpec mount descriptor name must be a string')
    assert(value.export == nil or type(value.export) == 'string',
        'DwarfSpec mount descriptor export must be a string or nil')
    return {kind=value.kind, name=value.name, export=value.export}
end

---Resolves one descriptor through its mount-owned TestBed.
---@param bed dwarfspec.TestBed
---@param descriptor table
---@return any
function M.resolve(bed, descriptor)
    local exported = descriptor.kind == 'module' and
        bed:require(descriptor.name) or bed:reqscript(descriptor.name)
    if descriptor.export == nil then return exported end
    assert(type(exported) == 'table',
        'DwarfSpec mount descriptor export requires a table result')
    local value = exported[descriptor.export]
    assert(value ~= nil, 'DwarfSpec mount descriptor export was not found: ' ..
        descriptor.export)
    return value
end

return M
