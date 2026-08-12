-- Verified definitions for mount and subject read-only queries.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyDefinition = require(
    'dwarfspec.driver.command.read_only_definition')

---@class dwarfspec.MountQueryDefinitions
---@field private _operations table<string, function>
---@field private _opaque dwarfspec.CommandOpaqueTokens
local MountQueries = {}
MountQueries.__index = MountQueries

---Creates the mount-query definition owner.
---@param operations table<string, function>
---@return dwarfspec.MountQueryDefinitions
function MountQueries.new(operations)
    assert(type(operations) == 'table',
        'mount queries require operations')
    for _, name in ipairs({'preflight', 'root', 'get', 'inspect',
            'capture_view_tree'}) do
        assert(type(operations[name]) == 'function',
            'mount queries require ' .. name)
    end
    return setmetatable({_operations=operations,
        _opaque=OpaqueTokens.new()}, MountQueries)
end

---Retains invocation arguments behind one plain token.
---@param values table
---@return table
function MountQueries:_request(values)
    return {arguments_token=self._opaque:retain(values)}
end

---Resolves retained invocation arguments.
---@param request table
---@return table
function MountQueries:_arguments(request)
    return self._opaque:resolve(request.arguments_token)
end

---Creates one mount query definition.
---@param name string
---@param normalize function
---@param execute function
---@return table
function MountQueries:_definition(name, normalize, execute)
    return ReadOnlyDefinition.new({name=name, kind=CommandKind.QUERY,
        normalize=normalize,
        preflight=function() return self._operations.preflight(name) end,
        execute=execute}):definition()
end

---Creates all public mount-query definitions.
---@return table[]
function MountQueries:definitions()
    return {
        self:_definition('root', function(arguments)
            return self:_request({options=arguments.options})
        end, function(_, request)
            return self._operations.root(self:_arguments(request).options)
        end),
        self:_definition('get', function(arguments)
            return self:_request({control_path=arguments.control_path,
                options=arguments.options})
        end, function(_, request)
            local arguments = self:_arguments(request)
            return self._operations.get(arguments.control_path,
                arguments.options)
        end),
        self:_definition('inspect', function(arguments)
            return self:_request({view=arguments.view})
        end, function(_, request)
            return self._operations.inspect(self:_arguments(request).view)
        end),
        self:_definition('capture_view_tree', function(arguments)
            return self:_request({name=arguments.name,
                options=arguments.options})
        end, function(_, request)
            local arguments = self:_arguments(request)
            return self._operations.capture_view_tree(arguments.name,
                arguments.options)
        end),
    }
end

---Registers and binds public mount queries.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param operations table<string, function>
function MountQueries.bind(ds, command_runner, operations)
    local owner = MountQueries.new(operations)
    for _, definition in ipairs(owner:definitions()) do
        command_runner:registerBuiltin(definition)
    end

    ---Returns the selected current-mount root subject.
    ---@param options? table
    ---@param command_options? table
    ---@return table
    function ds.root(options, command_options)
        return command_runner:invoke('root', {options=options}, command_options)
    end

    ---Returns a subject for one current source path.
    ---@param control_path any
    ---@param options? table
    ---@param command_options? table
    ---@return table
    function ds.get(control_path, options, command_options)
        return command_runner:invoke('get', {control_path=control_path,
            options=options}, command_options)
    end

    ---Returns stable diagnostics for one current subject.
    ---@param view? table
    ---@param command_options? table
    ---@return table
    function ds.inspect(view, command_options)
        return command_runner:invoke('inspect', {view=view}, command_options)
    end

    ---Captures one bounded current source tree.
    ---@param name string
    ---@param options? table
    ---@param command_options? table
    ---@return table
    function ds.capture_view_tree(name, options, command_options)
        return command_runner:invoke('capture_view_tree', {name=name,
            options=options}, command_options)
    end
end

return MountQueries
