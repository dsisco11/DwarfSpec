-- Verified definition for the rendered-text search query.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')

---@class dwarfspec.SearchCommandDefinition
---@field private _dependencies table
---@field private _subjects dwarfspec.CommandSubjectTokens
local SearchDefinition = {}
SearchDefinition.__index = SearchDefinition

---Creates the rendered-text search definition owner.
---@param dependencies table
---@return dwarfspec.SearchCommandDefinition
function SearchDefinition.new(dependencies)
    assert(type(dependencies) == 'table',
        'search command dependencies are required')
    for _, name in ipairs({'normalize_query', 'normalize_rectangle', 'search'}) do
        assert(type(dependencies[name]) == 'function',
            'search command requires ' .. name)
    end
    assert(type(dependencies.mount_context) == 'table',
        'search command requires mount_context')
    return setmetatable({_dependencies=dependencies,
        _subjects=SubjectTokens.new()}, SearchDefinition)
end

---Normalizes one public search request.
---@param arguments table
---@param subject_token? table
---@return table
function SearchDefinition:_normalize(arguments, subject_token)
    local request = {query=self._dependencies.normalize_query(arguments.query)}
    if subject_token ~= nil then
        request.subject_token = subject_token
    elseif arguments.search_area ~= nil then
        request.area = self._dependencies.normalize_rectangle(
            arguments.search_area, 'text search area')
    end
    return request
end

---Revalidates the current mount and optional mounted subject.
---@param request table
---@param subject? table
---@return table
function SearchDefinition:_preflight(request, subject)
    local mount_context = self._dependencies.mount_context
    local mount = mount_context:require_current('search')
    mount.interaction_target:assert_current('search')
    if subject ~= nil then
        mount_context:resolve_subject(subject, 'search')
    end
    return {target_identity=subject and subject.control_path or
        '<current-mount>', subject=subject}
end

---Creates the immutable query definition.
---@return table
function SearchDefinition:definition()
    local dependencies = self._dependencies
    return {name='search', kind=CommandKind.QUERY,
        normalize=function(arguments)
            local subject_token
            if arguments.search_area_is_subject then
                subject_token = self._subjects:retain(arguments.search_area)
            end
            return self:_normalize(arguments, subject_token)
        end,
        preflight=function(context, request)
            local subject = request.subject_token and
                self._subjects:resolve(request.subject_token) or nil
            return Outcomes.ready(self:_preflight(request, subject))
        end,
        execute=function(context, request, readiness)
            return Outcomes.ready(
                dependencies.search(request.query,
                    readiness.subject or request.area))
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION}
end

---Registers and binds the public rendered-text search command.
---@param ds table
---@param command_runner dwarfspec.CommandRunner
---@param dependencies table
---@return dwarfspec.CommandDefinition
function SearchDefinition.bind(ds, command_runner, dependencies)
    assert(type(ds) == 'table', 'search command requires the public namespace')
    assert(type(command_runner) == 'table' and
            type(command_runner.registerBuiltin) == 'function' and
            type(command_runner.invoke) == 'function',
        'search command requires the verified command runner')
    local definition = command_runner:registerBuiltin(
        SearchDefinition.new(dependencies):definition())

    ---Searches rendered text through the verified query contract.
    ---@param query any
    ---@param search_area? any
    ---@param command_options? table
    ---@return table|nil
    function ds.search(query, search_area, command_options)
        return command_runner:invoke('search', {query=query,
            search_area=search_area,
            search_area_is_subject=dependencies.mount_context
                :is_subject(search_area)},
            command_options)
    end
    return definition
end

return SearchDefinition
