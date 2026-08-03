-- Direct behavioral contracts for external-process application orchestration.

local application = require('dwarfspec.controller.application')
local runner_module = require('dwarfspec.controller.execution.runner')

---Creates one append-only stream compatible with application output.
---@return table
local function stream()
    local value = {text=''}
    ---Appends one fragment to the stream.
    ---@param fragment string
    function value:write(fragment)
        self.text = self.text .. fragment
    end
    return value
end

---Creates an isolated application context and records controller calls.
---@return table, table, table, table
local function fixture()
    local output = stream()
    local errors = stream()
    local calls = {}
    local directories = {
        project={'tests'},
        ['project/tests']={'sample.ds.lua'},
    }
    local files = {['project/tests/sample.ds.lua']=true}
    local filesystem = {
        isdir=function(path)
            return directories[path:gsub('\\', '/')] ~= nil
        end,
        isfile=function(path)
            return files[path:gsub('\\', '/')] == true
        end,
        listdir=function(path)
            return directories[path:gsub('\\', '/')]
        end,
        currentdir=function() return 'project' end,
    }
    local controller = {}
    for _, method in ipairs({
            'run', 'status', 'history', 'inspect', 'logs', 'abort',
            'recover_executor'}) do
        controller[method] = function(options, ...)
            table.insert(calls, {
                method=method,
                options=options,
                arguments={...},
            })
            return {exit_code=0}
        end
    end
    return {
        package_root='package',
        current_directory='project',
        filesystem=filesystem,
        environment={getenv=function() return nil end},
        output=output,
        errors=errors,
        runner=controller,
    }, calls, output, errors
end

describe('DwarfSpec application', function()
    it('orchestrates help, version, list, and run commands', function()
        local context, calls, output = fixture()
        assert.equals(0, application.main({}, context))
        assert.matches('Usage:', output.text, 1, true)

        output.text = ''
        assert.equals(0, application.main({'version'}, context))
        assert.equals('DwarfSpec 0.2.2\n', output.text)

        output.text = ''
        assert.equals(0, application.main({'list'}, context))
        assert.equals('tests/sample.ds.lua\n', output.text)

        output.text = ''
        assert.equals(0, application.main({'run', '--no-results'}, context))
        assert.equals('run', calls[1].method)
        assert.same({'tests/sample.ds.lua'}, calls[1].options.identities)
        assert.equals('project', calls[1].options.project_root)
        assert.is_function(calls[1].options.emit)
    end)

    it('selects every scheduler, inspection, and recovery operation', function()
        local context, calls = fixture()
        local commands = {
            {'status'},
            {'history'},
            {'show', 'shown-run'},
            {'logs', 'logged-run'},
            {'abort', 'aborted-run'},
            {'recover-executor', 'blocked-run', '--generation=7',
                '--reason=verified clean'},
        }
        for _, arguments in ipairs(commands) do
            assert.equals(0, application.main(arguments, context))
        end
        assert.same({
            'status', 'history', 'inspect', 'logs', 'abort', 'recover_executor',
        }, (function()
            local methods = {}
            for _, call in ipairs(calls) do table.insert(methods, call.method) end
            return methods
        end)())
        assert.equals('shown-run', calls[3].arguments[1])
        assert.equals('logged-run', calls[4].arguments[1])
        assert.equals('aborted-run', calls[5].arguments[1])
        assert.equals('blocked-run', calls[6].arguments[1])
        assert.equals(7, calls[6].arguments[2])
        assert.equals('verified clean', calls[6].arguments[3])
    end)

    it('prints retained output only when returned by the controller', function()
        local context, _, output = fixture()
        context.runner.logs = function()
            return {exit_code=0, logs={found=true, lines={'one', 'two\n'}}}
        end
        assert.equals(0, application.main({'logs', 'run'}, context))
        assert.equals('one\ntwo\n', output.text)

        output.text = ''
        context.runner.logs = function()
            return {exit_code=0, logs={found=false}}
        end
        assert.equals(0, application.main({'logs', 'missing'}, context))
        assert.equals('', output.text)
    end)

    it('returns controller exit codes and preserves reported errors', function()
        local context, _, output, errors = fixture()
        context.runner.run = function()
            return {exit_code=19, error={message='controller failed'}}
        end
        assert.equals(19, application.main({'run', '--no-results'}, context))
        assert.equals('', output.text)
        assert.equals('controller failed\n', errors.text)
    end)

    it('classifies usage and dependency exceptions distinctly', function()
        local context, calls, _, errors = fixture()
        assert.equals(runner_module.exit_codes[
            runner_module.failure_kinds.USAGE],
            application.main({'unknown'}, context))
        assert.matches('unknown command: unknown', errors.text, 1, true)
        assert.same({}, calls)

        errors.text = ''
        context.runner.status = function() error('transport exploded') end
        assert.equals(runner_module.exit_codes[
            runner_module.failure_kinds.DEPENDENCY],
            application.main({'status'}, context))
        assert.matches('transport exploded', errors.text, 1, true)
    end)

    it('forwards process dependencies and output emission to the runner',
            function()
        local context, calls, output = fixture()
        context.host_scripts = {run='host-run'}
        context.invoke = function() end
        context.system = 'windows'
        context.now = function() return 1 end
        context.sleep = function() end
        context.decode_json = function() end
        assert.equals(0, application.main({'run', '--no-results'}, context))
        local options = calls[1].options
        assert.same(context.host_scripts, options.host_scripts)
        assert.equals(context.invoke, options.invoke)
        assert.equals('windows', options.system)
        assert.equals(context.now, options.now)
        assert.equals(context.sleep, options.sleep)
        assert.equals(context.decode_json, options.decode_json)
        options.emit('runner line')
        assert.equals('runner line\n', output.text)
    end)
end)
