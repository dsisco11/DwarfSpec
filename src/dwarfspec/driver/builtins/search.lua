-- Verified definition for the rendered-text search query.

local CommandKind = require('dwarfspec.protocol.enums.command_kinds')
local IntrinsicKind = require(
    'dwarfspec.protocol.enums.intrinsic_verification_kinds')
local Outcomes = require('dwarfspec.driver.command.outcomes')
local RetryPolicy = require(
    'dwarfspec.protocol.enums.execution_retry_policies')
local SubjectTokens = require('dwarfspec.driver.command.subject_tokens')
local TextSearch = require('dwarfspec.driver.commands.text_search')
local Definition = require('dwarfspec.driver.command.definition')

---@class dwarfspec.SearchCommandDefinition
---@field private _runtime dwarfspec.SearchRuntime
---@field private _subjects dwarfspec.CommandSubjectTokens
local SearchDefinition = {}
SearchDefinition.__index = SearchDefinition

---Creates the rendered-text search command owner.
---@param runtime dwarfspec.SearchRuntime
---@return dwarfspec.SearchCommandDefinition
function SearchDefinition.new(runtime)
    assert(type(runtime) == 'table', 'search command runtime is required')
    for _, name in ipairs({'is_subject', 'preflight', 'search'}) do
        assert(type(runtime[name]) == 'function',
            'search command runtime requires ' .. name)
    end
    return setmetatable({_runtime=runtime,
        _subjects=SubjectTokens.new()}, SearchDefinition)
end

---Normalizes one public search request.
---@param arguments table
---@param subject_token? table
---@return table
function SearchDefinition:_normalize(arguments, subject_token)
    local request = {query=TextSearch.normalize_query(arguments.query)}
    if subject_token ~= nil then
        request.subject_token = subject_token
    elseif arguments.search_area ~= nil then
        request.area = TextSearch.normalize_rectangle(
            arguments.search_area, 'text search area')
    end
    return request
end

---Revalidates the current mount and optional mounted subject.
---@param request table
---@param subject? table
---@return table
function SearchDefinition:_preflight(request, subject)
    return self._runtime:preflight(subject)
end

---Creates the immutable query definition.
---@return table
function SearchDefinition:definition()
    return Definition.validate({name='search', kind=CommandKind.QUERY,
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
            local subject = request.subject_token and
                self._subjects:resolve(request.subject_token) or nil
            return Outcomes.ready(
                self._runtime:search(request.query,
                    subject or request.area, subject ~= nil))
        end,
        execution_retry_policy=RetryPolicy.ONCE,
        intrinsic_verification=IntrinsicKind.PRIMARY_OBSERVATION})
end

---Adapts the public search signature for the runner.
---@param query any
---@param search_area? any
---@param command_options? table
---@return table, table|nil
function SearchDefinition:arguments(query, search_area, command_options)
    return {query=query, search_area=search_area,
        search_area_is_subject=self._runtime:is_subject(search_area)},
        command_options
end

return SearchDefinition
