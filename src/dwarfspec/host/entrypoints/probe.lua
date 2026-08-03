-- Production adapter that verifies access to DFHack's core Lua context.

---Returns the available DFHack table through the active script environment.
---@return table|nil
local function dfhack_context()
    local ok, context = pcall(function() return dfhack end)
    return ok and type(context) == 'table' and context or nil
end

---Returns the normalized core-context capability value.
---@param context table|nil
---@return string
local function core_capability(context)
    if context and type(context.is_core_context) == 'boolean' then
        return tostring(context.is_core_context)
    end
    return 'unavailable'
end

---Returns the normalized timeout capability type.
---@param context table|nil
---@return string
local function timeout_capability(context)
    if not context then return 'unavailable' end
    return type(context.timeout)
end

---Returns an optional safe DFHack version field.
---@param context table|nil
---@return string
local function version_field(context)
    if not context or context.VERSION == nil then return '' end
    local ok, version = pcall(tostring, context.VERSION)
    if not ok or not version:match('^[A-Za-z0-9._+-]+$') then return '' end
    return ' dfhack=' .. version
end

local context = dfhack_context()
print(('DWARFSPEC_PROBE protocol=2 core=%s timeout=%s%s')
    :format(core_capability(context), timeout_capability(context),
        version_field(context)))
