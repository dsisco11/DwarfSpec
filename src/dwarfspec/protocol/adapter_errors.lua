-- Canonical construction, validation, and serialization for adapter errors.

local events = require('dwarfspec.protocol.events')
local RunnerFailureKind =
    require('dwarfspec.protocol.enums.runner_failure_kinds')
local SchedulerFailureKind =
    require('dwarfspec.protocol.enums.scheduler_failure_kinds')

local M = {
    protocol=2,
    schema='dwarfspec.error.v1',
}

local COMMON_FIELDS = {
    operation='string',
    run_id='string',
    generation='positive_integer',
    state='string',
    blocking_run_id='string',
    blocking_generation='positive_integer',
}

local FORBIDDEN_FIELDS = {
    authorization_proof=true,
    owner_capability=true,
    package_root=true,
    project_root=true,
    result_path=true,
}

local KNOWN_CODES = {
    package_version_mismatch={
        kind=RunnerFailureKind.REGISTRATION,
        required={
            running_version='string',
            requested_version='string',
        },
    },
    [SchedulerFailureKind.PROJECT_BUSY]={
        kind=RunnerFailureKind.REGISTRATION,
        required={
            blocking_run_id='string',
            blocking_generation='positive_integer',
            state='string',
            reason='string',
        },
    },
    [SchedulerFailureKind.REQUEST_KEY_CONFLICT]={
        kind=RunnerFailureKind.REGISTRATION,
        required={
            blocking_run_id='string',
            blocking_generation='positive_integer',
            state='string',
            reason='string',
        },
    },
    [SchedulerFailureKind.RESULT_PATH_BUSY]={
        kind=RunnerFailureKind.REGISTRATION,
        required={
            blocking_run_id='string',
            blocking_generation='positive_integer',
            state='string',
            reason='string',
        },
    },
}

local APPROVED_KINDS = {
    [RunnerFailureKind.REGISTRATION]=true,
    [RunnerFailureKind.EXECUTOR_QUARANTINED]=true,
    [RunnerFailureKind.HOST]=true,
}

---Returns whether a value is a positive integer.
---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---Validates one field against its public adapter-error type.
---@param value any
---@param field_type string
---@param field_name string
local function validate_field(value, field_type, field_name)
    if field_type == 'positive_integer' then
        assert(is_positive_integer(value),
            'DwarfSpec adapter error field ' .. field_name ..
                ' must be a positive integer')
    else
        assert(type(value) == field_type and value ~= '',
            'DwarfSpec adapter error field ' .. field_name ..
                ' must be a non-empty ' .. field_type)
    end
end

---Returns a safe bounded rendering of an arbitrary internal exception.
---@param value any
---@return string
function M.safe_message(value)
    local ok, rendered = pcall(tostring, value)
    if not ok or type(rendered) ~= 'string' then
        return 'DwarfSpec host reported an unprintable internal error'
    end
    rendered = rendered:gsub('^.-:%d+: ', '')
        :gsub('[%z\1-\31\127]', '?')
    if rendered == '' then rendered = 'DwarfSpec host reported an internal error' end
    if #rendered > 512 then rendered = rendered:sub(1, 509) .. '...' end
    return rendered
end

---Constructs one detached JSON-safe domain rejection value.
---@param code string
---@param message string
---@param fields table|nil
---@return table
function M.domain(code, message, fields)
    assert(type(code) == 'string' and code ~= '',
        'DwarfSpec domain rejection code must be a non-empty string')
    assert(type(message) == 'string' and message ~= '',
        'DwarfSpec domain rejection message must be a non-empty string')
    local rejection = {code=code, message=message}
    for name, value in pairs(fields or {}) do rejection[name] = value end
    events.copy_json(rejection, 'DwarfSpec domain rejection')
    local candidate = {
        schema=M.schema,
        protocol=M.protocol,
        kind=KNOWN_CODES[code] and KNOWN_CODES[code].kind or
            RunnerFailureKind.HOST,
    }
    for name, value in pairs(rejection) do candidate[name] = value end
    M.validate(candidate)
    return rejection
end

---Constructs the compatibility executor-quarantine adapter error.
---@param value table
---@return table
function M.executor_quarantine(value)
    local response = {
        schema=M.schema,
        protocol=M.protocol,
        kind=RunnerFailureKind.EXECUTOR_QUARANTINED,
        blocking_run_id=value.blocking_run_id,
        blocking_generation=value.blocking_generation,
        reason=value.reason,
        message=('DwarfSpec executor is quarantined by run %s generation %s: ' ..
            '%s. Recover it with: dwarfspec recover-executor %s --generation %s')
            :format(M.safe_message(value.blocking_run_id),
                M.safe_message(value.blocking_generation),
                M.safe_message(value.reason), M.safe_message(value.blocking_run_id),
                M.safe_message(value.blocking_generation)),
    }
    return M.validate(response)
end

---Constructs a canonical envelope from a domain rejection or internal fault.
---@param value any
---@param default_kind string
---@return table
function M.envelope(value, default_kind)
    if type(value) == 'table' and
            value.kind == 'executor_quarantined' then
        return M.executor_quarantine(value)
    end
    local response = {
        schema=M.schema,
        protocol=M.protocol,
        kind=default_kind,
        message=M.safe_message(value),
    }
    if type(value) == 'table' and type(value.code) == 'string' and
            value.code ~= '' then
        for name, field_value in pairs(value) do
            if name ~= 'kind' then response[name] = field_value end
        end
    end
    return M.validate(response)
end

---Validates and returns one canonical adapter-error envelope.
---@param response table
---@return table
function M.validate(response)
    events.copy_json(response, 'adapter error response')
    assert(response.schema == M.schema,
        'unsupported DwarfSpec adapter error schema: ' .. tostring(response.schema))
    assert(response.protocol == M.protocol,
        'unsupported DwarfSpec protocol: ' .. tostring(response.protocol))
    assert(APPROVED_KINDS[response.kind],
        'unsupported DwarfSpec adapter error kind: ' .. tostring(response.kind))
    validate_field(response.message, 'string', 'message')
    if response.code ~= nil then
        local label = response.kind == RunnerFailureKind.REGISTRATION and
            'registration error code' or 'adapter error code'
        assert(type(response.code) == 'string' and response.code ~= '',
            'DwarfSpec ' .. label .. ' must be a non-empty string')
    end

    for name in pairs(FORBIDDEN_FIELDS) do
        assert(response[name] == nil,
            'DwarfSpec adapter error forbids field ' .. name)
    end
    for name, field_type in pairs(COMMON_FIELDS) do
        local quarantine_field =
            response.kind == RunnerFailureKind.EXECUTOR_QUARANTINED and
            response.code == nil and
            (name == 'blocking_run_id' or name == 'blocking_generation')
        if response[name] ~= nil and not quarantine_field then
            validate_field(response[name], field_type, name)
        end
    end

    local allowed = {schema=true, protocol=true, kind=true, code=true, message=true}
    for name in pairs(COMMON_FIELDS) do allowed[name] = true end
    local contract = response.code and KNOWN_CODES[response.code]
    if contract then
        assert(response.kind == contract.kind,
            'DwarfSpec adapter error code has incompatible kind')
        for name, field_type in pairs(contract.required) do
            if response.code == 'package_version_mismatch' and
                    name == 'running_version' then
                assert(type(response[name]) == 'string' and response[name] ~= '',
                    'DwarfSpec package version mismatch requires running version')
            elseif response.code == 'package_version_mismatch' and
                    name == 'requested_version' then
                assert(type(response[name]) == 'string' and response[name] ~= '',
                    'DwarfSpec package version mismatch requires requested version')
            else
                validate_field(response[name], field_type, name)
            end
            allowed[name] = true
        end
    elseif response.kind == RunnerFailureKind.EXECUTOR_QUARANTINED and
            response.code == nil then
        assert(type(response.blocking_run_id) == 'string' and
            response.blocking_run_id ~= '',
            'DwarfSpec quarantine error requires blocking run id')
        assert(is_positive_integer(response.blocking_generation),
            'DwarfSpec quarantine error requires blocking generation')
        assert(type(response.reason) == 'string' and response.reason ~= '',
            'DwarfSpec quarantine error requires a reason')
        allowed.reason = true
    end
    for name in pairs(response) do
        assert(allowed[name], 'DwarfSpec adapter error has unsupported field ' .. name)
    end
    return response
end

---Serializes one canonical adapter error with a non-throwing host-fault fallback.
---@param value any
---@param default_kind string
---@param encoder function
---@return string, table
function M.serialize(value, default_kind, encoder)
    local built, response = pcall(M.envelope, value, default_kind)
    if not built then
        response = {
            schema=M.schema,
            protocol=M.protocol,
            kind=RunnerFailureKind.HOST,
            message='DwarfSpec host could not serialize an adapter error',
        }
    end
    local encoded, json = pcall(encoder, response, {pretty=false})
    if encoded and type(json) == 'string' then return json, response end
    response = {
        schema=M.schema,
        protocol=M.protocol,
        kind=RunnerFailureKind.HOST,
        message='DwarfSpec host could not serialize an adapter error',
    }
    local fallback = '{"schema":"dwarfspec.error.v1","protocol":2,' ..
        '"kind":"host","message":' ..
        '"DwarfSpec host could not serialize an adapter error"}'
    return fallback, response
end

return M
