-- Driver-owned staging workflow for real overlay registration tests.

local M = {}

---@class dwarfspec.OverlayRegistrationTransaction
---@field private _run_id string
---@field private _project table
---@field private _services table
---@field private _snapshots table<string, table>
---@field private _next_token integer
local Transaction = {}
Transaction.__index = Transaction

---Runs one cleanup operation while retaining failures for later aggregation.
---@param failures string[]
---@param name string
---@param action function
local function attempt(failures, name, action)
    local ok, failure = xpcall(action, debug.traceback)
    if not ok then
        table.insert(failures, name .. ': ' .. tostring(failure))
    end
end

---Returns whether the configuration artifact exactly matches its snapshot.
---@param services table
---@param existed boolean
---@param contents string|nil
---@return boolean
local function config_matches(services, existed, contents)
    if existed ~= services.isfile(services.config_path) then return false end
    return not existed or services.read_file(services.config_path) == contents
end

---Returns a cleanup verification result without replacing prior failures.
---@param check function
---@return boolean
local function safe_check(check)
    local ok, result = pcall(check)
    return ok and not not result
end

---Restores every external artifact owned by one staged registration script.
---@param staged table
---@param services table
---@param source_contents string
---@param config_existed boolean
---@param config_contents string|nil
local function restore(staged, services, source_contents, config_existed,
        config_contents)
    if staged.cleanup_state.complete then return end
    local failures = {}
    local names = {}
    attempt(failures, 'enumerate staged overlays', function()
        names = services.registered_names(staged.script_name)
    end)
    for _, name in ipairs(names) do
        attempt(failures, 'disable ' .. name, function()
            if services.is_enabled(name) then services.disable(name) end
        end)
    end
    attempt(failures, 'remove staged script', function()
        if not services.isfile(staged.path) then return end
        assert(services.read_file(staged.path) == source_contents,
            'refusing to remove a modified overlay registration script: ' ..
                staged.path)
        local removed, remove_error = services.remove_file(staged.path)
        assert(removed ~= false and removed ~= nil, remove_error)
    end)
    attempt(failures, 'restore overlay configuration', function()
        if config_existed then
            services.write_file(services.config_path, config_contents)
        elseif services.isfile(services.config_path) then
            local removed, remove_error =
                services.remove_file(services.config_path)
            assert(removed ~= false and removed ~= nil, remove_error)
        end
    end)
    attempt(failures, 'final overlay rescan', services.rescan)
    attempt(failures, 'verify staged script removal', function()
        assert(not services.isfile(staged.path),
            'staged overlay registration script still exists: ' ..
                staged.path)
    end)
    attempt(failures, 'verify overlay configuration restoration', function()
        assert(config_matches(services, config_existed, config_contents),
            'overlay configuration was not restored exactly')
    end)
    attempt(failures, 'verify registration removal', function()
        assert(#services.registered_names(staged.script_name) == 0,
            'staged overlay registrations remain after cleanup')
    end)
    local script_removed = safe_check(function()
        return not services.isfile(staged.path)
    end)
    local config_restored = safe_check(function()
        return config_matches(services, config_existed, config_contents)
    end)
    local registrations_removed = safe_check(function()
        return #services.registered_names(staged.script_name) == 0
    end)
    staged.cleanup_state = {
        complete=#failures == 0,
        script_removed=script_removed,
        config_restored=config_restored,
        registrations_removed=registrations_removed,
        failures=failures,
    }
    if #failures > 0 then
        error('overlay registration cleanup failed: ' ..
            table.concat(failures, '; '), 0)
    end
end

---Stages one real overlay registration and owns exact external restoration.
---@param source_path string
---@param logical_name string
---@param run_id string
---@param project table
---@param cleanup table
---@param services table
---@return table
local function stage(source_path, logical_name, run_id, project, cleanup,
        services)
    assert(type(logical_name) == 'string' and
        logical_name:match('^[a-z][a-z0-9_-]*$'),
        'overlay registration name must contain lowercase letters, digits, ' ..
            'hyphens, or underscores')
    assert(type(run_id) == 'string' and run_id:match('^[%w_.-]+$'),
        'overlay staging requires a safe run id')
    assert(type(services.destination_directory) == 'string' and
        services.destination_directory ~= '',
        'overlay staging requires a destination directory')
    assert(type(services.config_path) == 'string' and
        services.config_path ~= '',
        'overlay staging requires an overlay configuration path')
    local source = project.resolve_lua_source(
        source_path, 'overlay registration')
    local leaf = ('dwarfspec_%s_%s.lua'):format(run_id, logical_name)
    local separator = package.config:sub(1, 1)
    local destination = services.destination_directory .. separator .. leaf
    assert(not services.isfile(destination),
        'refusing to overwrite an existing overlay registration script: ' ..
            destination)
    local source_contents = services.read_file(source.absolute_path)
    local config_existed = services.isfile(services.config_path)
    local config_contents = config_existed and
        services.read_file(services.config_path) or nil
    local staged = {
        name=logical_name,
        script_name=leaf:gsub('%.lua$', ''),
        path=destination,
        source=source.relative_path,
        registered_names={},
        cleanup_state={complete=false},
    }
    local marker = cleanup.mark()
    cleanup.register(
        'restore overlay registration ' .. logical_name, function()
            restore(staged, services, source_contents, config_existed,
                config_contents)
        end)
    local ok, failure = xpcall(function()
        services.write_file(destination, source_contents)
        services.rescan()
        staged.registered_names = services.registered_names(
            staged.script_name)
        assert(#staged.registered_names > 0,
            'staged script did not register any OVERLAY_WIDGETS')
    end, debug.traceback)
    if not ok then
        local cleanup_ok, cleanup_failures = cleanup.rollback(
            marker, 'failed overlay registration staging')
        local message = 'overlay registration staging failed: ' ..
            tostring(failure)
        if not cleanup_ok then
            local details = {}
            for _, cleanup_failure in ipairs(cleanup_failures) do
                table.insert(details, cleanup_failure.message)
            end
            message = message .. '; cleanup failed: ' ..
                table.concat(details, '; ')
        end
        error(message, 2)
    end
    return staged
end

---Validates shared overlay services used by both registration paths.
---@param services table
function Transaction.validate_services(services)
    for _, name in ipairs({
            'isfile', 'read_file', 'write_file', 'remove_file', 'rescan',
            'registered_names', 'is_enabled', 'disable'}) do
        assert(type(services[name]) == 'function',
            'overlay registration requires overlay.' .. name .. '()')
    end
end

---Prepares inert resource identities and exact restoration state.
---@param source_path string
---@param logical_name string
---@return table
function Transaction:prepare(source_path, logical_name)
    assert(type(logical_name) == 'string' and
        logical_name:match('^[a-z][a-z0-9_-]*$'),
        'overlay registration name must contain lowercase letters, digits, ' ..
            'hyphens, or underscores')
    local source = self._project.resolve_lua_source(
        source_path, 'overlay registration')
    local leaf = ('dwarfspec_%s_%s.lua'):format(self._run_id, logical_name)
    local destination = self._services.destination_directory ..
        package.config:sub(1, 1) .. leaf
    assert(not self._services.isfile(destination),
        'refusing to overwrite an existing overlay registration script: ' ..
            destination)
    return {
        name=logical_name, script_name=leaf:gsub('%.lua$', ''),
        path=destination, source=source.relative_path,
        source_absolute_path=source.absolute_path,
        claims={{claim_key='overlay_script', resource_kind='file',
            resource_identity=destination, exclusive=true},
            {claim_key='overlay_config', resource_kind='file',
                resource_identity=self._services.config_path,
                exclusive=true}},
    }
end

---Creates the prepared registration without using the legacy cleanup registry.
---@param prepared table
---@return table
function Transaction:stage(prepared)
    self._next_token = self._next_token + 1
    local token = ('overlay-%d'):format(self._next_token)
    local config_existed = self._services.isfile(self._services.config_path)
    local snapshot = {
        source_contents=self._services.read_file(prepared.source_absolute_path),
        config_existed=config_existed,
        config_contents=config_existed and
            self._services.read_file(self._services.config_path) or nil,
    }
    self._snapshots[token] = snapshot
    local staged = {name=prepared.name, script_name=prepared.script_name,
        path=prepared.path, source=prepared.source, registered_names={},
        snapshot_token=token, cleanup_state={complete=false}}
    local ok, failure = xpcall(function()
        self._services.write_file(staged.path, snapshot.source_contents)
        self._services.rescan()
        staged.registered_names = self._services.registered_names(
            staged.script_name)
        assert(#staged.registered_names > 0,
            'staged script did not register any OVERLAY_WIDGETS')
    end, debug.traceback)
    if not ok then
        local restored, restore_failure = xpcall(function()
            restore(staged, self._services, snapshot.source_contents,
                snapshot.config_existed, snapshot.config_contents)
        end, debug.traceback)
        if restored then self._snapshots[token] = nil end
        local message = 'overlay registration staging failed: ' ..
            tostring(failure)
        if not restored then
            message = message .. '; cleanup failed: ' ..
                tostring(restore_failure)
        end
        error(message, 2)
    end
    return staged
end

---Returns exact post-effect bindings for the prepared claims.
---@param staged table
---@return table[]
function Transaction:bindings(staged)
    return {{claim_key='overlay_script', resource_identity=staged.path},
        {claim_key='overlay_config',
            resource_identity=self._services.config_path}}
end

---Verifies the staged script and its discovered registrations.
---@param staged table
---@return boolean
function Transaction:verify(staged)
    local snapshot = assert(self._snapshots[staged.snapshot_token],
        'overlay registration snapshot is unavailable')
    return self._services.isfile(staged.path) and
        self._services.read_file(staged.path) == snapshot.source_contents and
        #self._services.registered_names(staged.script_name) > 0
end

---Restores every artifact captured by the transaction receipt.
---@param staged table
function Transaction:restore(staged)
    local snapshot = assert(self._snapshots[staged.snapshot_token],
        'overlay registration snapshot is unavailable')
    local mutable = {}
    for name, value in pairs(staged) do mutable[name] = value end
    mutable.cleanup_state = {complete=false}
    restore(mutable, self._services, snapshot.source_contents,
        snapshot.config_existed, snapshot.config_contents)
end

---Verifies exact absence and configuration restoration after cleanup.
---@param staged table
---@return boolean
function Transaction:verify_absent(staged)
    local snapshot = assert(self._snapshots[staged.snapshot_token],
        'overlay registration snapshot is unavailable')
    local verified = not self._services.isfile(staged.path) and
        config_matches(self._services, snapshot.config_existed,
            snapshot.config_contents) and
        #self._services.registered_names(staged.script_name) == 0
    if verified then self._snapshots[staged.snapshot_token] = nil end
    return verified
end

---Constructs the resource-transaction adapter for verified commands.
---@param capabilities table
---@return dwarfspec.OverlayRegistrationTransaction
function M.new_transaction(capabilities)
    assert(type(capabilities) == 'table',
        'overlay registration requires run capabilities')
    local services = assert(capabilities.overlay,
        'overlay registration requires overlay capabilities')
    Transaction.validate_services(services)
    assert(type(services.destination_directory) == 'string' and
            services.destination_directory ~= '',
        'overlay staging requires a destination directory')
    assert(type(services.config_path) == 'string' and
            services.config_path ~= '',
        'overlay staging requires an overlay configuration path')
    return setmetatable({_run_id=assert(capabilities.run_id,
        'overlay registration requires a run id'),
        _project=assert(capabilities.project,
            'overlay registration requires project capabilities'),
        _services=services, _snapshots={}, _next_token=0}, Transaction)
end

---Constructs one run-scoped overlay registration workflow.
---@param capabilities table
---@return table
function M.new(capabilities)
    assert(type(capabilities) == 'table',
        'overlay registration requires run capabilities')
    local run_id = assert(capabilities.run_id,
        'overlay registration requires a run id')
    local project = assert(capabilities.project,
        'overlay registration requires project capabilities')
    local cleanup = assert(capabilities.cleanup,
        'overlay registration requires cleanup capabilities')
    local services = assert(capabilities.overlay,
        'overlay registration requires overlay capabilities')
    assert(type(project.resolve_lua_source) == 'function',
        'overlay registration requires project.resolve_lua_source()')
    for _, name in ipairs({'mark', 'register', 'rollback'}) do
        assert(type(cleanup[name]) == 'function',
            'overlay registration requires cleanup.' .. name .. '()')
    end
    for _, name in ipairs({
            'isfile', 'read_file', 'write_file', 'remove_file', 'rescan',
            'registered_names', 'is_enabled', 'disable'}) do
        assert(type(services[name]) == 'function',
            'overlay registration requires overlay.' .. name .. '()')
    end

    local workflow = {}

    ---Stages one run-owned overlay registration source.
    ---@param source_path string
    ---@param logical_name string
    ---@return table
    function workflow.stage(source_path, logical_name)
        return stage(source_path, logical_name, run_id, project, cleanup,
            services)
    end

    return workflow
end

return M
