-- Verified definitions for scalar native game-state queries.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.GameQueryDefinitions
---@field private _queries table<string, function>
local GameQueries = {}
GameQueries.__index = GameQueries

---Creates the native game-query definition owner.
---@param queries table<string, function>
---@return dwarfspec.GameQueryDefinitions
function GameQueries.new(queries)
    assert(type(queries) == 'table', 'game queries require operations')
    for _, name in ipairs({'isGamePaused', 'getGameSpeed', 'getTick',
            'getTime', 'getSaveDirectoryName', 'hasFocus'}) do
        assert(type(queries[name]) == 'function',
            'game queries require ' .. name)
    end
    return setmetatable({_queries=queries}, GameQueries)
end

---Creates one scalar query definition.
---@param name string
---@param normalize function
---@param execute function
---@return table
function GameQueries:_definition(name, normalize, execute)
    return ReadOnlyDefinition.new({name=name, kind=CommandKind.QUERY,
        normalize=normalize, execute=execute}):definition()
end

---Creates all scalar game-state query definitions.
---@return table[]
function GameQueries:definitions()
    local no_arguments = function() return {} end
    local definitions = {}
    for _, name in ipairs({'isGamePaused', 'getGameSpeed', 'getTick',
            'getTime', 'getSaveDirectoryName'}) do
        local query_name = name
        definitions[#definitions + 1] = self:_definition(query_name,
            no_arguments,
            function() return self._queries[query_name]() end)
    end
    definitions[#definitions + 1] = self:_definition('hasFocus',
        function(arguments)
            assert(type(arguments.path) == 'string' and arguments.path ~= '',
                'focus path must be a nonempty string')
            return {path=arguments.path}
        end,
        function(_, request) return self._queries.hasFocus(request.path) end)
    return definitions
end

---Registers and binds all scalar native game-state queries.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param queries table<string, function>
function GameQueries.bind(ds, command_runner, queries)
    local owner = GameQueries.new(queries)
    for _, definition in ipairs(owner:definitions()) do
        command_runner:registerBuiltin(definition)
    end
    for _, name in ipairs({'isGamePaused', 'getGameSpeed', 'getTick',
            'getTime', 'getSaveDirectoryName'}) do
        ---Invokes one scalar native query through the verified runner.
        ---@param command_options? table
        ---@return any
        ds[name] = function(command_options)
            return command_runner:invoke(name, {}, command_options)
        end
    end

    ---Returns whether the current native focus matches one path.
    ---@param path string
    ---@param command_options? table
    ---@return boolean
    function ds.hasFocus(path, command_options)
        return command_runner:invoke('hasFocus', {path=path}, command_options)
    end
end

return GameQueries
