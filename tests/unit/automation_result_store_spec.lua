-- Unit contracts for stable version 2 latest-result persistence.

local json = require('dkjson')
local lfs = require('lfs')
local ResultState = require('dwarfspec.automation.result_states')
local result_store = require('dwarfspec.automation.result_store')

---Builds one complete terminal result fixture.
---@param root string
---@param run_id string
---@param state DwarfSpecResultState|nil
---@return table
local function result(root, run_id, state)
    state = state or ResultState.PASSED
    return result_store.build({
        service_instance_id='service-result-store',
        project_id='project-' .. run_id,
        run_id=run_id,
        generation=1,
        state=state,
        terminal=true,
        exit_code=state == ResultState.PASSED and 0 or 6,
        project_root=root,
        selection={identities={'tests/live/shared_spec.ds.lua'}},
        submitted_at='2026-07-23T11:00:00Z',
        activated_at='2026-07-23T11:00:01Z',
        finished_at='2026-07-23T11:00:02Z',
        queue_wait_ms=1,
        host_report={state=state},
        events={},
    })
end

---Reads and decodes one persisted result.
---@param path string
---@return table
local function read_result(path)
    local file = assert(io.open(path, 'rb'))
    local contents = assert(file:read('*a'))
    file:close()
    return assert(json.decode(contents))
end

---Removes only files owned by one result-store test.
---@param path string
local function cleanup(path)
    os.remove(path)
    os.remove(path .. '.tmp')
end

describe('automation result store', function()
    it('resolves default, relative, absolute, and space-containing files',
            function()
        local root = lfs.currentdir():gsub('\\', '/') ..
            '/tests/framework/service project beta'
        local default_path = result_store.resolve_path(root, nil)
        assert.equals(root ..
            '/tests/.test-results/dwarfspec/results.json', default_path)
        assert.equals(root .. '/custom output/latest result.json',
            result_store.resolve_path(root,
                'custom output/latest result.json'))
        assert.equals('D:/shared output/results.json',
            result_store.resolve_path(root,
                'D:/shared output/results.json'))
        assert.is_nil(result_store.resolve_path(root, false))
        assert.has_error(function()
            result_store.resolve_path(root, '../outside/results.json')
        end, 'relative file path must remain beneath its project root')
    end)

    it('replaces two sequential invocations with exactly the second result',
            function()
        local root = lfs.currentdir():gsub('\\', '/') ..
            '/tests/framework/service_project_alpha'
        local path = result_store.resolve_path(root)
        cleanup(path)

        result_store.write(path, result(root, 'first-invocation'))
        result_store.write(path, result(root, 'second-invocation'))

        local persisted = read_result(path)
        assert.equals('second-invocation', persisted.run_id)
        assert.is_nil(io.open(path .. '.tmp', 'rb'))
        cleanup(path)
    end)

    it('keeps two project-local default files independent', function()
        local cwd = lfs.currentdir():gsub('\\', '/')
        local alpha = cwd .. '/tests/framework/service_project_alpha'
        local beta = cwd .. '/tests/framework/service project beta'
        local alpha_path = result_store.resolve_path(alpha)
        local beta_path = result_store.resolve_path(beta)
        cleanup(alpha_path)
        cleanup(beta_path)

        result_store.write(alpha_path, result(alpha, 'alpha-result'))
        result_store.write(beta_path, result(beta, 'beta-result'))

        assert.equals('alpha-result', read_result(alpha_path).run_id)
        assert.equals('beta-result', read_result(beta_path).run_id)
        assert.is_not.equals(alpha_path, beta_path)
        cleanup(alpha_path)
        cleanup(beta_path)
    end)

    it('cleans its temporary sibling after classified replacement failure',
            function()
        local root = lfs.currentdir():gsub('\\', '/') ..
            '/tests/framework/command_project'
        local path = root ..
            '/tests/.test-results/result-store-failure/results.json'
        cleanup(path)
        result_store.write(path, result(root, 'retained-result'))

        assert.has_error(function()
            result_store.write(path, result(root, 'rejected-result'), {
                replace_file=function()
                    return nil, 'injected replacement failure'
                end,
            })
        end, 'could not replace result file: injected replacement failure')
        assert.equals('retained-result', read_result(path).run_id)
        assert.is_nil(io.open(path .. '.tmp', 'rb'))
        cleanup(path)
    end)

    it('cleans its temporary sibling after an open failure', function()
        local root = lfs.currentdir():gsub('\\', '/') ..
            '/tests/framework/command_project'
        local path = root ..
            '/tests/.test-results/result-store-open/results.json'
        cleanup(path)

        assert.has_error(function()
            result_store.write(path, result(root, 'open-failure'), {
                open_file=function()
                    return nil, 'injected open failure'
                end,
            })
        end, 'could not open temporary result: injected open failure')
        assert.is_nil(io.open(path .. '.tmp', 'rb'))
        cleanup(path)
    end)
end)
