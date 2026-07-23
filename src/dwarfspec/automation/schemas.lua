-- Versioned schema validators for automation service data contracts.

local events = require('dwarfspec.automation.events')

local M = {
    protocol_version=2,
}

local RUN_STATES = {
    queued=true,
    starting=true,
    running=true,
    cleaning=true,
    passed=true,
    failed=true,
    aborted=true,
    cancelled=true,
}

local TERMINAL_RUN_STATES = {
    passed=true,
    failed=true,
    aborted=true,
    cancelled=true,
}

local RESULT_STATES = {
    queued=true,
    starting=true,
    running=true,
    cleaning=true,
    passed=true,
    failed=true,
    aborted=true,
    cancelled=true,
    usage_error=true,
    dependency_error=true,
    connection_error=true,
    registration_error=true,
    queue_timeout=true,
    host_error=true,
    timeout=true,
    interrupted=true,
    persistence_error=true,
}

local NONTERMINAL_RESULT_STATES = {
    queued=true,
    starting=true,
    running=true,
    cleaning=true,
}

local IDENTITY_OPTIONAL_RESULT_STATES = {
    usage_error=true,
    dependency_error=true,
    connection_error=true,
    registration_error=true,
    host_error=true,
}

---Returns whether a value is a nonnegative integer.
---@param value any
---@return boolean
local function is_nonnegative_integer(value)
    return type(value) == 'number' and value >= 0 and value % 1 == 0
end

---Requires one nonempty string field.
---@param value table
---@param field string
---@param contract string
local function require_string(value, field, contract)
    assert(type(value[field]) == 'string' and value[field] ~= '',
        contract .. ' has invalid field: ' .. field)
end

---Requires one table field.
---@param value table
---@param field string
---@param contract string
local function require_table(value, field, contract)
    assert(type(value[field]) == 'table',
        contract .. ' has invalid field: ' .. field)
end

---Requires one nonnegative integer field.
---@param value table
---@param field string
---@param contract string
local function require_integer(value, field, contract)
    assert(is_nonnegative_integer(value[field]),
        contract .. ' has invalid field: ' .. field)
end

---Requires the current service protocol.
---@param value table
---@param contract string
local function require_protocol(value, contract)
    assert(value.protocol_version == M.protocol_version,
        ('unsupported %s protocol: %s')
            :format(contract, tostring(value.protocol_version)))
end

---Requires one schema discriminator.
---@param value any
---@param schema string
---@param contract string
local function require_schema(value, schema, contract)
    assert(type(value) == 'table', contract .. ' must be a table')
    assert(value.schema == schema,
        ('unsupported %s schema: %s')
            :format(contract, tostring(value.schema)))
end

---Validates one complete Busted count record.
---@param value table
---@param contract string
local function validate_counts(value, contract)
    assert(type(value) == 'table', contract .. ' must be a table')
    for _, field in ipairs({
            'successes', 'failures', 'errors', 'pending'}) do
        assert(is_nonnegative_integer(value[field]),
            contract .. ' has invalid field: ' .. field)
    end
end

---Validates one project summary embedded in a public snapshot.
---@param project table
local function validate_project(project)
    assert(type(project) == 'table',
        'scheduler project summary must be a table')
    require_string(project, 'project_id', 'scheduler project summary')
    require_string(project, 'normalized_project_root',
        'scheduler project summary')
    require_string(project, 'display_name', 'scheduler project summary')
    require_string(project, 'result_policy', 'scheduler project summary')
end

---Validates one version 2 service snapshot.
---@param value table
---@return table
function M.validate_service(value)
    require_schema(value, 'dwarfspec.service.v2', 'automation service')
    require_protocol(value, 'automation service')
    for _, field in ipairs({
            'service_instance_id', 'package_root', 'package_version'}) do
        require_string(value, field, 'automation service')
    end
    for _, field in ipairs({
            'generation', 'project_count', 'run_count'}) do
        require_integer(value, field, 'automation service')
    end
    require_table(value, 'queue', 'automation service')
    require_table(value, 'quarantine', 'automation service')
    require_table(value, 'latest_terminal_results', 'automation service')
    assert(type(value.quarantine.active) == 'boolean',
        'automation service quarantine must declare active')
    for index, run_id in ipairs(value.queue) do
        assert(type(run_id) == 'string' and run_id ~= '',
            'automation service queue has invalid run id at ' .. index)
    end
    events.copy_json(value, 'automation service')
    return value
end

---Validates one version 2 scheduler snapshot.
---@param value table
---@return table
function M.validate_scheduler(value)
    require_schema(value, 'dwarfspec.scheduler.v2',
        'automation scheduler')
    require_protocol(value, 'automation scheduler')
    for _, field in ipairs({
            'service_instance_id', 'package_root', 'package_version'}) do
        require_string(value, field, 'automation scheduler')
    end
    require_table(value, 'queue', 'automation scheduler')
    require_table(value, 'projects', 'automation scheduler')
    require_table(value, 'quarantine', 'automation scheduler')
    assert(type(value.quarantine.active) == 'boolean',
        'automation scheduler quarantine must declare active')
    if value.quarantine.active then
        require_string(value.quarantine, 'reason',
            'automation scheduler quarantine')
    end
    assert((value.active_run_id == nil) ==
        (value.active_project_id == nil),
        'automation scheduler active run and project must appear together')
    for index, entry in ipairs(value.queue) do
        assert(type(entry) == 'table',
            'automation scheduler queue entry must be a table')
        require_string(entry, 'run_id',
            'automation scheduler queue entry ' .. index)
        require_string(entry, 'project_id',
            'automation scheduler queue entry ' .. index)
    end
    for _, project in ipairs(value.projects) do validate_project(project) end
    events.copy_json(value, 'automation scheduler')
    return value
end

---Validates one version 2 immutable run snapshot.
---@param value table
---@return table
function M.validate_run(value)
    require_schema(value, 'dwarfspec.run.v2', 'automation run')
    require_protocol(value, 'automation run')
    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id', 'state',
            'owner_kind'}) do
        require_string(value, field, 'automation run')
    end
    assert(RUN_STATES[value.state] == true,
        'automation run has unsupported state: ' .. tostring(value.state))
    assert(type(value.terminal) == 'boolean' and
        value.terminal == (TERMINAL_RUN_STATES[value.state] == true),
        'automation run terminal flag does not match state')
    for _, field in ipairs({
            'generation', 'submitted_at_ms', 'last_sequence'}) do
        require_integer(value, field, 'automation run')
    end
    assert(value.generation > 0,
        'automation run generation must be positive')
    for _, field in ipairs({
            'counts', 'totals', 'queue_lease', 'execution_lease',
            'failures'}) do
        require_table(value, field, 'automation run')
    end
    validate_counts(value.counts, 'automation run counts')
    validate_counts(value.totals, 'automation run totals')
    assert(type(value.queue_lease.active) == 'boolean',
        'automation run queue lease must declare active')
    assert(type(value.execution_lease.active) == 'boolean',
        'automation run execution lease must declare active')
    if value.queue_position ~= nil then
        assert(is_nonnegative_integer(value.queue_position) and
            value.queue_position > 0,
            'automation run queue position must be positive')
    end
    for _, field in ipairs({
            'activated_at_ms', 'queue_wait_ms', 'current_repeat'}) do
        if value[field] ~= nil then
            assert(is_nonnegative_integer(value[field]),
                'automation run has invalid field: ' .. field)
        end
    end
    if value.current_test ~= nil then
        require_string(value, 'current_test', 'automation run')
    end
    if value.cleanup_reason ~= nil then
        require_string(value, 'cleanup_reason', 'automation run')
    end
    if value.host_error ~= nil then
        assert(type(value.host_error) == 'table',
            'automation run host error must be a table')
    end
    for index, failure in ipairs(value.failures) do
        assert(type(failure) == 'table',
            'automation run failure must be a table at ' .. index)
        for _, field in ipairs({'kind', 'name', 'message'}) do
            require_string(failure, field,
                'automation run failure ' .. index)
        end
    end
    assert(type(value.cleanup_confirmed) == 'boolean',
        'automation run cleanup confirmation must be boolean')
    assert(type(value.mount_cleanup_verified) == 'boolean',
        'automation run mount cleanup verification must be boolean')
    events.copy_json(value, 'automation run')
    return value
end

---Validates one event through the shared envelope contract.
---@param value table
---@param expected table|nil
---@return table
function M.validate_event(value, expected)
    return events.validate(value, expected)
end

---Validates one version 2 status transport response.
---@param value table
---@param expected table|nil
---@return table
function M.validate_transport(value, expected)
    require_schema(value, 'dwarfspec.transport.v2',
        'automation transport')
    assert(value.protocol == M.protocol_version,
        'unsupported automation transport protocol: ' ..
            tostring(value.protocol))
    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id'}) do
        require_string(value, field, 'automation transport')
        if expected and expected[field] ~= nil then
            assert(value[field] == expected[field],
                'automation transport identity mismatch: ' .. field)
        end
    end
    require_integer(value, 'generation', 'automation transport')
    assert(value.generation > 0,
        'automation transport generation must be positive')
    if expected and expected.generation ~= nil then
        assert(value.generation == expected.generation,
            'automation transport identity mismatch: generation')
    end
    require_table(value, 'snapshot', 'automation transport')
    require_table(value, 'events', 'automation transport')
    require_integer(value, 'last_sequence', 'automation transport')
    M.validate_run(value.snapshot)
    for _, field in ipairs({
            'service_instance_id', 'project_id', 'run_id', 'generation'}) do
        assert(value.snapshot[field] == value[field],
            'automation transport snapshot identity mismatch: ' .. field)
    end

    local after_sequence = expected and expected.after_sequence or 0
    assert(is_nonnegative_integer(after_sequence),
        'automation transport cursor must be a nonnegative integer')
    for index, event in ipairs(value.events) do
        events.validate(event, value)
        local expected_sequence = after_sequence + index
        assert(event.sequence == expected_sequence,
            ('automation transport event sequence discontinuity: ' ..
             'expected %d, found %s')
                :format(expected_sequence, tostring(event.sequence)))
    end
    assert(value.last_sequence == after_sequence + #value.events,
        'automation transport last sequence does not match returned events')
    assert(value.snapshot.last_sequence == value.last_sequence,
        'automation transport snapshot sequence does not match journal')
    events.copy_json(value, 'automation transport')
    return value
end

---Validates one version 2 persisted invocation result.
---@param value table
---@return table
function M.validate_result(value)
    require_schema(value, 'dwarfspec.result.v2',
        'automation result')
    require_string(value, 'state', 'automation result')
    assert(RESULT_STATES[value.state] == true,
        'automation result has unsupported state: ' .. tostring(value.state))
    assert(type(value.terminal) == 'boolean',
        'automation result terminal flag must be boolean')
    assert(value.terminal == (NONTERMINAL_RESULT_STATES[value.state] ~= true),
        'automation result terminal flag does not match state')
    require_string(value, 'project_root', 'automation result')
    require_table(value, 'selection', 'automation result')
    require_table(value, 'events', 'automation result')
    require_table(value.selection, 'identities',
        'automation result selection')
    for index, selected in ipairs(value.selection.identities) do
        assert(type(selected) == 'string' and selected ~= '',
            'automation result selection has invalid identity at ' .. index)
    end
    if value.error ~= nil then
        assert(type(value.error) == 'table',
            'automation result error must be a table')
        require_string(value.error, 'kind', 'automation result error')
        require_string(value.error, 'message', 'automation result error')
    end

    local identity_fields = {
        'service_instance_id', 'project_id', 'run_id', 'generation',
    }
    local identity_present = value.service_instance_id ~= nil or
        value.project_id ~= nil or value.run_id ~= nil or
        value.generation ~= nil
    assert(identity_present or
        IDENTITY_OPTIONAL_RESULT_STATES[value.state] == true,
        'automation result state requires a service run identity')
    if identity_present then
        for _, field in ipairs(identity_fields) do
            assert(value[field] ~= nil,
                'automation result has incomplete identity: ' .. field)
        end
        for _, field in ipairs({
                'service_instance_id', 'project_id', 'run_id'}) do
            require_string(value, field, 'automation result')
        end
        require_integer(value, 'generation', 'automation result')
        assert(value.generation > 0,
            'automation result generation must be positive')
    end

    local previous_sequence = 0
    for _, event in ipairs(value.events) do
        events.validate(event, identity_present and value or nil)
        assert(event.sequence == previous_sequence + 1,
            'automation result event sequence discontinuity')
        previous_sequence = event.sequence
    end
    events.copy_json(value, 'automation result')
    return value
end

return M
