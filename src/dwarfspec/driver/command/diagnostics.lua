-- Bounded serialization-safe diagnostics for verified command execution.

---@class dwarfspec.CommandDiagnostics
---@field private _max_depth integer
---@field private _max_entries integer
---@field private _max_string_length integer
---@field private _pending_sample_limit integer
---@field private _max_records integer
---@field private _entries table[]
---@field private _pending table<string, table>
---@field private _dropped_entries integer
---@field private _dropped_pending integer
local Diagnostics = {}
Diagnostics.__index = Diagnostics

---@class dwarfspec.driver.command.DiagnosticsInternals
local Internals = {}

---Validates a positive integer diagnostic limit.
---@param value any
---@param label string
---@return integer
function Internals.positive_integer(value, label)
    assert(type(value) == 'number' and value >= 1 and value % 1 == 0 and
        value < math.huge, label .. ' must be a positive finite integer')
    return value
end

---Creates a read-only proxy over detached diagnostic data.
---@param data table
---@param label string
---@return table
function Internals.read_only(data, label)
    return setmetatable({}, {
        __index=data,
        __newindex=function() error(label .. ' is immutable', 2) end,
        __pairs=function() return pairs(data) end,
        __len=function() return #data end,
        __metatable=false,
    })
end

---Copies plain data within one shared size budget.
---@param diagnostics dwarfspec.CommandDiagnostics
---@param value any
---@param label string
---@param depth integer
---@param budget table
---@param active table
---@return any
function Internals.copy_plain(diagnostics, value, label, depth, budget, active)
    local value_type = type(value)
    if value_type ~= 'table' then
        assert(value_type == 'nil' or value_type == 'boolean' or
            value_type == 'number' or value_type == 'string',
            label .. ' must contain only plain data')
        if value_type == 'number' then
            assert(value == value and value > -math.huge and value < math.huge,
                label .. ' numbers must be finite')
        elseif value_type == 'string' then
            assert(#value <= diagnostics._max_string_length,
                label .. ' strings must be bounded')
        end
        return value
    end
    assert(depth < diagnostics._max_depth,
        label .. ' nesting must be bounded')
    assert(not active[value], label .. ' cannot contain cycles')
    active[value] = true
    local copy = {}
    for key, entry in pairs(value) do
        local key_type = type(key)
        assert(key_type == 'string' or
            (key_type == 'number' and key >= 1 and key % 1 == 0),
            label .. ' keys must be strings or positive integers')
        budget.entries = budget.entries + 1
        assert(budget.entries <= diagnostics._max_entries,
            label .. ' entries must be bounded')
        copy[key] = Internals.copy_plain(diagnostics, entry, label, depth + 1,
            budget, active)
    end
    active[value] = nil
    return Internals.read_only(copy, label)
end

---Copies a string while guaranteeing the configured bound.
---@param diagnostics dwarfspec.CommandDiagnostics
---@param value any
---@return string
function Internals.bounded_string(diagnostics, value)
    local succeeded, text = pcall(tostring, value)
    if not succeeded then text = '<unprintable diagnostic error>' end
    if #text <= diagnostics._max_string_length then return text end
    if diagnostics._max_string_length <= 3 then
        return text:sub(1, diagnostics._max_string_length)
    end
    return text:sub(1, diagnostics._max_string_length - 3) .. '...'
end

---Counts keys without depending on sequence layout.
---@param value table
---@return integer
function Internals.key_count(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

---Creates a diagnostics collector with explicit finite limits.
---@param options? table
---@return dwarfspec.CommandDiagnostics
function Diagnostics.new(options)
    options = options or {}
    local instance = setmetatable({}, Diagnostics)
    instance._max_depth = Internals.positive_integer(
        options.max_depth or 8, 'diagnostic max_depth')
    instance._max_entries = Internals.positive_integer(
        options.max_entries or 128, 'diagnostic max_entries')
    instance._max_string_length = Internals.positive_integer(
        options.max_string_length or 4096, 'diagnostic max_string_length')
    assert(instance._max_string_length >= 64,
        'diagnostic max_string_length must be at least 64')
    instance._pending_sample_limit = Internals.positive_integer(
        options.pending_sample_limit or 3,
        'diagnostic pending_sample_limit')
    instance._max_records = Internals.positive_integer(
        options.max_records or 64, 'diagnostic max_records')
    instance._entries = {}
    instance._pending = {}
    instance._dropped_entries = 0
    instance._dropped_pending = 0
    return instance
end

---Validates, detaches, and freezes bounded plain evidence.
---@param value any
---@param label? string
---@return any
function Diagnostics:sanitize(value, label)
    return Internals.copy_plain(self, value, label or 'diagnostic evidence', 0,
        {entries=0}, {})
end

---Records one bounded diagnostic entry.
---@param kind string
---@param evidence table
---@return table
function Diagnostics:record(kind, evidence)
    assert(type(kind) == 'string' and kind ~= '',
        'diagnostic kind must be a nonempty string')
    assert(#kind <= self._max_string_length,
        'diagnostic kind must be bounded')
    assert(type(evidence) == 'table',
        'diagnostic evidence must be a table')
    local entry = self:sanitize({kind=kind, evidence=evidence},
        'diagnostic entry')
    if #self._entries < self._max_records then
        self._entries[#self._entries + 1] = entry
    else
        self._dropped_entries = self._dropped_entries + 1
    end
    return entry
end

---Aggregates repeated pending observations without retaining every sample.
---@param stage string
---@param reason string
---@param evidence? table
---@return table
function Diagnostics:record_pending(stage, reason, evidence)
    assert(type(stage) == 'string' and stage ~= '',
        'pending stage must be a nonempty string')
    assert(type(reason) == 'string' and reason ~= '',
        'pending reason must be a nonempty string')
    assert(#stage <= self._max_string_length and
        #reason <= self._max_string_length,
        'pending stage and reason must be bounded')
    local key = stage .. '\0' .. reason
    local aggregate = self._pending[key]
    if not aggregate then
        if Internals.key_count(self._pending) >= self._max_records then
            self._dropped_pending = self._dropped_pending + 1
            return self:sanitize({
                stage=stage, reason=reason, count=1, samples={},
                retained=false,
            }, 'pending aggregate')
        end
        aggregate = {stage=stage, reason=reason, count=0, samples={}}
        self._pending[key] = aggregate
    end
    aggregate.count = aggregate.count + 1
    local sample = evidence == nil and nil or
        self:sanitize(evidence, 'pending observation')
    if sample ~= nil then
        if #aggregate.samples < self._pending_sample_limit then
            aggregate.samples[#aggregate.samples + 1] = sample
        else
            aggregate.samples[#aggregate.samples] = sample
        end
    end
    return self:sanitize(aggregate, 'pending aggregate')
end

---Runs a command-kind diagnostic provider and sanitizes only its projection.
---@param provider fun(request: any, receipt: any): table
---@param request any
---@param receipt any
---@return table|nil evidence
---@return table|nil provider_failure
function Diagnostics:project(provider, request, receipt)
    assert(type(provider) == 'function',
        'diagnostic provider must be callable')
    local succeeded, projected = pcall(provider, request, receipt)
    if not succeeded then
        local failure = self:record('diagnostic_provider_failed', {
            message=Internals.bounded_string(self, projected),
        })
        return nil, failure
    end
    local sanitized, result = pcall(function()
        assert(type(projected) == 'table',
            'diagnostic provider must return a table')
        return self:sanitize(projected, 'diagnostic projection')
    end)
    if not sanitized then
        local failure = self:record('diagnostic_provider_failed', {
            message=Internals.bounded_string(self, result),
        })
        return nil, failure
    end
    return result, nil
end

---Records artifact-capture failure alongside, never instead of, command failure.
---@param artifact string
---@param capture_error any
---@param originating_failure table
---@return table
function Diagnostics:record_artifact_failure(artifact, capture_error,
        originating_failure)
    assert(type(artifact) == 'string' and artifact ~= '',
        'artifact name must be a nonempty string')
    assert(#artifact <= self._max_string_length,
        'artifact name must be bounded')
    local origin = self:sanitize(originating_failure,
        'originating command failure')
    return self:record('artifact_capture_failed', {
        artifact=artifact,
        message=Internals.bounded_string(self, capture_error),
        originating_failure=origin,
    })
end

---Returns immutable retained diagnostics and pending summaries.
---@return table
function Diagnostics:snapshot()
    local pending = {}
    for _, aggregate in pairs(self._pending) do
        pending[#pending + 1] = self:sanitize(aggregate,
            'pending aggregate snapshot')
    end
    table.sort(pending, function(left, right)
        if left.stage == right.stage then return left.reason < right.reason end
        return left.stage < right.stage
    end)
    local entries = {}
    for index, entry in ipairs(self._entries) do entries[index] = entry end
    return Internals.read_only({
        entries=Internals.read_only(entries, 'diagnostic entries'),
        pending=Internals.read_only(pending, 'pending summaries'),
        dropped_entries=self._dropped_entries,
        dropped_pending=self._dropped_pending,
    }, 'diagnostic snapshot')
end

return Diagnostics
