-- Validated construction of controller-to-host command vectors.

local project = require('dwarfspec.controller.discovery.project')
local ResultPolicy = require('dwarfspec.protocol.enums.result_policies')

local M = {}

---Returns whether a file can be opened for reading.
---@param path string
---@return boolean
local function is_file(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

---Creates a command builder for one package layout.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies) == 'table', 'command builder dependencies are required')
    local fail = assert(dependencies.fail, 'command builder failure callback is required')
    local dependency_kind = assert(dependencies.dependency_kind,
        'command builder dependency failure kind is required')
    local file_exists = dependencies.file_exists or is_file
    local builder = {}

    ---Returns one installed or source-tree host entry script path.
    ---@param options table
    ---@param name string
    ---@return string
    function builder.host_script(options, name)
        local scripts = assert(options.host_scripts,
            'DwarfSpec host entry-script layout is required')
        local path = scripts[name]
        assert(path, 'DwarfSpec layout does not define host entry script: ' .. name)
        return path
    end

    ---Resolves the shared Lua module root for source and installed layouts.
    ---@param package_root string
    ---@return string
    function builder.lua_module_root(package_root)
        if file_exists(project.join(package_root, 'busted/core.lua')) then
            return package_root
        end
        local lua_version = assert(_VERSION:match('Lua (%d+%.%d+)'),
            'could not determine the active Lua version from ' .. tostring(_VERSION))
        return project.join(package_root, '.luarocks/share/lua/' .. lua_version)
    end

    ---Validates the pure-Lua dependencies and every host command entrypoint.
    ---@param options table
    function builder.validate_dependencies(options)
        local lua_root = builder.lua_module_root(options.package_root)
        for _, path in ipairs({
                project.join(lua_root, 'busted/core.lua'),
                project.join(lua_root, 'busted/init.lua'),
                project.join(lua_root, 'luassert/init.lua'),
                builder.host_script(options, 'bootstrap'),
                builder.host_script(options, 'status'),
                builder.host_script(options, 'recover'),
                builder.host_script(options, 'recover_executor'),
                builder.host_script(options, 'scheduler_status'),
                builder.host_script(options, 'run_query'),
                builder.host_script(options, 'abort'),
                builder.host_script(options, 'acknowledge'),
                builder.host_script(options, 'probe')}) do
            if not file_exists(path) then
                fail(dependency_kind, 'DwarfSpec dependency was not found: ' .. path)
            end
        end
    end

    ---Builds the connection-probe command vector.
    ---@param options table
    ---@return string[]
    function builder.probe(options)
        return {'lua', '-f', builder.host_script(options, 'probe')}
    end

    ---Builds the bootstrap command vector for one selected run.
    ---@param options table
    ---@param run_id string
    ---@return string[]
    function builder.bootstrap(options, run_id)
        local result_policy = options.result_path and ResultPolicy.FILE or ResultPolicy.NONE
        local arguments = {
            'lua', '-f', builder.host_script(options, 'bootstrap'), run_id,
            '--project-root=' .. options.project_root,
            '--repeat=' .. tostring(options.repeat_count),
            '--defer-frames=' .. tostring(options.startup_delay_frames),
            '--lease-timeout-ms=' .. tostring(options.lease_timeout_ms),
            '--lease-check-frames=' .. tostring(options.lease_check_frames),
            '--test-glob=' .. tostring(options.test_glob or '*.ds.lua'),
            '--lua-module-root=' .. builder.lua_module_root(options.package_root),
            '--result-policy=' .. result_policy,
        }
        if options.result_path then
            table.insert(arguments, '--result-path=' .. options.result_path)
        end
        local repeated = {
            filter=options.filters,
            ['filter-out']=options.filter_out,
            name=options.names,
            tag=options.tags,
            ['exclude-tag']=options.exclude_tags,
        }
        for _, name in ipairs({'filter', 'filter-out', 'name', 'tag', 'exclude-tag'}) do
            for _, value in ipairs(repeated[name] or {}) do
                table.insert(arguments, '--' .. name .. '=' .. value)
            end
        end
        for _, identity in ipairs(options.identities) do
            table.insert(arguments, '--spec=' .. project.host_spec(identity))
        end
        return arguments
    end

    ---Builds a run-poll command vector that also renews the owner lease.
    ---@param options table
    ---@param run_id string
    ---@param owner_capability string
    ---@param after_sequence integer
    ---@return string[]
    function builder.poll(options, run_id, owner_capability, after_sequence)
        return {'lua', '-f', builder.host_script(options, 'status'), run_id,
            owner_capability, tostring(after_sequence)}
    end

    ---Builds a scheduler-status command vector.
    ---@param options table
    ---@return string[]
    function builder.scheduler_status(options)
        return {'lua', '-f', builder.host_script(options, 'scheduler_status')}
    end

    ---Builds a retained-run query command vector.
    ---@param options table
    ---@param operation string
    ---@param run_id string|nil
    ---@return string[]
    function builder.query(options, operation, run_id)
        local arguments = {'lua', '-f', builder.host_script(options, 'run_query'), operation}
        if run_id ~= nil then table.insert(arguments, run_id) end
        return arguments
    end

    ---Builds a terminal acknowledgement command vector.
    ---@param options table
    ---@param run_id string
    ---@param generation integer
    ---@param owner_capability string
    ---@param after_sequence integer
    ---@return string[]
    function builder.acknowledge(options, run_id, generation, owner_capability, after_sequence)
        return {'lua', '-f', builder.host_script(options, 'acknowledge'), run_id,
            tostring(generation), owner_capability, tostring(after_sequence)}
    end

    ---Builds a queued cancellation or active recovery command vector.
    ---@param options table
    ---@param run_id string
    ---@param owner_capability string|nil
    ---@param after_sequence integer
    ---@return string[]
    function builder.recover(options, run_id, owner_capability, after_sequence)
        if owner_capability ~= nil then
            return {'lua', '-f', builder.host_script(options, 'recover'), run_id,
                owner_capability, tostring(after_sequence), 'external runner recovery'}
        end
        return {'lua', '-f', builder.host_script(options, 'abort'), run_id, '',
            tostring(after_sequence)}
    end

    ---Builds an explicit abort command vector.
    ---@param options table
    ---@param run_id string
    ---@return string[]
    function builder.abort(options, run_id)
        return {'lua', '-f', builder.host_script(options, 'abort'), run_id}
    end

    ---Builds an exact quarantined-executor recovery command vector.
    ---@param options table
    ---@param run_id string
    ---@param generation integer
    ---@param reason string
    ---@return string[]
    function builder.recover_executor(options, run_id, generation, reason)
        return {'lua', '-f', builder.host_script(options, 'recover_executor'),
            run_id, tostring(generation), '0', reason}
    end

    ---Returns whether an entrypoint exists for optional command preflight.
    ---@param options table
    ---@param name string
    ---@return boolean, string
    function builder.has_script(options, name)
        local path = builder.host_script(options, name)
        return file_exists(path), path
    end

    return builder
end

return M
