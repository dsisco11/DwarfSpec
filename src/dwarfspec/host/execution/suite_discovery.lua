-- Recursive, project-root-safe Busted suite discovery.

local M = {}

---Creates suite-discovery operations for one platform path convention.
---@param join_path function
---@return table
function M.new(join_path)
    local function list(value)
        if type(value) == 'table' then return value end
        if type(value) == 'string' and value ~= '' then return {value} end
        return {}
    end
    return {
        ---Builds standard Busted filter options.
        ---@param options table
        ---@return table
        filter_options=function(options)
            return {tags=list(options.tags), excludeTags=list(options.exclude_tags),
                filter=list(options.filters or options.filter), name=list(options.names),
                filterOut=list(options.filter_out), excludeNamesFile=nil, list=false,
                nokeepgoing=false, suppressPending=false}
        end,
        ---Discovers selected project-relative Lua specs recursively.
        ---@param project_root string
        ---@param loader function
        ---@param specs string[]|nil
        ---@return table
        discover=function(project_root, loader, specs)
            assert(type(project_root) == 'string' and project_root ~= '', 'project root must be a nonempty string')
            assert(type(loader) == 'function', 'live spec discovery requires a loader')
            specs = specs or {}; assert(#specs > 0, 'no live specs were selected')
            local roots = {}
            for _, spec in ipairs(specs) do
                assert(type(spec) == 'string' and spec ~= '' and spec:match('%.lua$') and not spec:match('^[/\\]') and not spec:match('^[A-Za-z]:[/\\]') and spec ~= '..' and not spec:match('^%.%.[/\\]') and not spec:match('[/\\]%.%.[/\\]') and not spec:match('[/\\]%.%.$'), 'live spec must name one safe project-relative Lua path')
                table.insert(roots, join_path(project_root, 'tests/' .. spec))
            end
            return loader(roots, {'%.lua$'}, {excludes={}, recursive=true, verbose=false})
        end,
    }
end

return M
