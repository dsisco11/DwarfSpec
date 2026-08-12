-- Shared opaque argument mechanics for one current-mount query owner.

local OpaqueTokens = require('dwarfspec.driver.command.opaque_tokens')
local ReadOnlyCommand = require(
    'dwarfspec.driver.builtins.read_only_command')

---@class dwarfspec.MountQueryCommand
---@field private _command dwarfspec.ReadOnlyBuiltinCommand
local MountQueryCommand = {}
MountQueryCommand.__index = MountQueryCommand

---Creates one current-mount query helper.
---@param options table
---@return dwarfspec.MountQueryCommand
function MountQueryCommand.new(options)
    local opaque = OpaqueTokens.new()
    return setmetatable({_command=ReadOnlyCommand.new({name=options.name,
        normalize=function(arguments)
            return {arguments_token=opaque:retain(
                options.request(arguments))}
        end,
        preflight=function() return options.runtime:preflight(options.name) end,
        execute=function(_, request)
            return options.execute(
                opaque:resolve(request.arguments_token))
        end})}, MountQueryCommand)
end

---Returns the immutable mount query definition.
---@return dwarfspec.CommandDefinition
function MountQueryCommand:definition() return self._command:definition() end

return MountQueryCommand
