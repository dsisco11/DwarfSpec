-- Run-owned configuration and targeting for unit-speed behavior.

local M = {}

local supported_fields = {
    fast_actions=true,
    teleport_jobs=true,
    unit_ids=true,
}

---Returns whether a value is an integer.
---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number' and value == value and
        value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---Creates an immutable sequence copied from the supplied values.
---@param values any[]
---@return table
local function immutable_sequence(values)
    local backing = {}
    for index, value in ipairs(values) do backing[index] = value end
    return setmetatable({}, {
        __index=backing,
        __len=function() return #backing end,
        __pairs=function() return pairs(backing) end,
        __newindex=function()
            error('normalized unit-speed configuration is immutable', 2)
        end,
        __metatable=false,
    })
end

---Creates an immutable normalized option record.
---@param fast_actions boolean
---@param teleport_jobs boolean
---@param unit_ids table|nil
---@return table
local function immutable_options(fast_actions, teleport_jobs, unit_ids)
    local backing = {
        fast_actions=fast_actions,
        teleport_jobs=teleport_jobs,
        unit_ids=unit_ids,
    }
    return setmetatable({}, {
        __index=backing,
        __pairs=function() return pairs(backing) end,
        __newindex=function()
            error('normalized unit-speed configuration is immutable', 2)
        end,
        __metatable=false,
    })
end

---Validates and copies the public unit-speed options.
---@param options table
---@return table
local function normalize_options(options)
    assert(type(options) == 'table',
        'setUnitSpeed options must be a table')
    for name in pairs(options) do
        assert(supported_fields[name],
            'unsupported setUnitSpeed option: ' .. tostring(name))
    end
    for _, name in ipairs({'fast_actions', 'teleport_jobs'}) do
        assert(options[name] == nil or type(options[name]) == 'boolean',
            'setUnitSpeed ' .. name .. ' must be a boolean')
    end
    local fast_actions = options.fast_actions == true
    local teleport_jobs = options.teleport_jobs == true
    assert(fast_actions or teleport_jobs,
        'setUnitSpeed requires fast_actions or teleport_jobs to be true')

    local copied_ids
    if options.unit_ids ~= nil then
        assert(type(options.unit_ids) == 'table',
            'setUnitSpeed unit_ids must be a nonempty array of integer ids')
        local count = 0
        local maximum = 0
        for key, id in pairs(options.unit_ids) do
            assert(is_integer(key) and key >= 1,
                'setUnitSpeed unit_ids must be a dense array')
            assert(is_integer(id),
                'setUnitSpeed unit_ids must contain only integer ids')
            count = count + 1
            if key > maximum then maximum = key end
        end
        assert(count > 0,
            'setUnitSpeed unit_ids must be a nonempty array')
        assert(maximum == count,
            'setUnitSpeed unit_ids must be a dense array')
        copied_ids = {}
        local seen = {}
        for index = 1, count do
            local id = options.unit_ids[index]
            assert(not seen[id],
                'setUnitSpeed unit_ids contains duplicate id: ' .. tostring(id))
            seen[id] = true
            copied_ids[index] = id
        end
    end
    return {
        fast_actions=fast_actions,
        teleport_jobs=teleport_jobs,
        unit_ids=copied_ids,
    }
end

---Creates one run-owned unit-speed controller.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table',
        'unit-speed controller requires dependencies')
    local recurring = assert(dependencies.recurring,
        'unit-speed controller requires recurring operation')
    local targets = assert(dependencies.targets,
        'unit-speed controller requires target adapter')
    local actions = assert(dependencies.actions,
        'unit-speed controller requires action adapter')
    assert(type(actions.accelerate) == 'function',
        'unit-speed action adapter requires accelerate')
    local job_travel = assert(dependencies.job_travel,
        'unit-speed controller requires job travel')
    assert(type(job_travel.attempt) == 'function',
        'unit-speed job travel requires attempt')
    local position_controller = assert(dependencies.position_controller,
        'unit-speed controller requires position controller')
    assert(type(position_controller.ensure_cleanup) == 'function',
        'unit-speed position controller requires ensure_cleanup')
    local register_cleanup = assert(dependencies.register_cleanup,
        'unit-speed controller requires cleanup registration')
    assert(type(register_cleanup) == 'function',
        'unit-speed cleanup registration must be a function')
    local controller = {
        active=false,
        configuration=nil,
        target_ids=nil,
    }

    ---Clears state after the recurring operation has been stopped.
    local function clear_state()
        controller.active = false
        controller.configuration = nil
        controller.target_ids = nil
    end

    ---Stops the active controller and releases its copied state.
    function controller:stop()
        recurring:stop()
        local was_active = self.active
        clear_state()
        return was_active
    end

    ---Activates immutable behavior and target snapshots for this example.
    ---@param options table
    function controller:activate(options)
        assert(not self.active and not recurring:is_active(),
            'setUnitSpeed is already active for this example')
        local normalized = normalize_options(options)
        targets:assert_ready()
        local captured
        if normalized.unit_ids == nil then
            captured = targets:capture_default_ids()
        else
            captured = targets:capture_explicit_ids(normalized.unit_ids)
        end
        position_controller:ensure_cleanup()
        local immutable_ids = immutable_sequence(captured)
        local configuration = immutable_options(
            normalized.fast_actions, normalized.teleport_jobs, immutable_ids)

        self.active = true
        self.configuration = configuration
        self.target_ids = immutable_ids
        register_cleanup('release unit speed configuration', function()
            clear_state()
        end)
        local ok, failure = pcall(function()
            recurring:start(function()
                if not targets:for_each_available(captured,
                        function(unit, id)
                            if configuration.teleport_jobs then
                                job_travel:attempt(id)
                            end
                            if configuration.fast_actions then
                                actions:accelerate(unit)
                            end
                        end) then
                    self:stop()
                end
            end, captured)
        end)
        if not ok then
            clear_state()
            error(failure, 2)
        end
    end

    return controller
end

return M
