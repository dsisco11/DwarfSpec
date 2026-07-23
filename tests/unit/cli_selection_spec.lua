-- Unit contracts for canonical identity globs, discovery, and CLI dispatch.

local cli = require('dwarfspec.cli')
local glob = require('dwarfspec.glob')
local project = require('dwarfspec.project')
local ResultPolicy = require('dwarfspec.automation.result_policies')

---Creates one append-only stream compatible with the CLI writer.
---@return table
local function stream()
    local value = {text=''}
    function value:write(fragment)
        self.text = self.text .. fragment
    end
    return value
end

describe('DwarfSpec canonical selection', function()
    it('implements documented case-sensitive segment and recursive globs',
            function()
        local identities = {
            'tests/automation/a_spec.lua',
            'tests/automation/nested/b_spec.lua',
            'tests/automation/nested/deeper/c_spec.lua',
        }
        assert.same({'tests/automation/a_spec.lua'},
            glob.select(identities, 'tests/automation/*_spec.lua'))
        assert.same(identities,
            glob.select(identities, 'tests/**/*_spec.lua'))
        assert.same({'tests/automation/nested/b_spec.lua'},
            glob.select(identities, 'tests/automation/nested/?_spec.lua'))
        assert.is_false(glob.matches('tests/automation/a_spec.lua',
            'tests/automation/A_spec.lua'))
        assert.is_true(glob.matches('tests/automation/star*_spec.lua',
            'tests/automation/star\\*_spec.lua'))
    end)

    it('rejects malformed globs distinctly', function()
        assert.has_error(function() glob.compile('tests/***/bad') end,
            'malformed glob: at most two adjacent stars are allowed')
        assert.has_error(function() glob.compile('tests/bad\\') end,
            'malformed glob: trailing escape character')
        assert.has_error(function() glob.compile('tests/[ab]') end,
            'malformed glob: character classes are not supported')
    end)

    it('discovers only stable canonical live-spec identities', function()
        local files = {
            ['project/tests/automation/a_spec.lua']=true,
            ['project/tests/automation/ordinary_spec.lua']=true,
            ['project/tests/automation/integration/registered_spec.lua']=true,
            ['project/tests/automation/support/external_screen.lua']=true,
        }
        local directories = {
            project={'tests'},
            ['project/tests']={'automation'},
            ['project/tests/automation']={'a_spec.lua', 'ordinary_spec.lua',
                'integration', 'support'},
            ['project/tests/automation/integration']={'registered_spec.lua'},
            ['project/tests/automation/support']={'external_screen.lua'},
        }
        local filesystem = {
            isfile=function(path) return files[path:gsub('\\', '/')] end,
            isdir=function(path)
                return directories[path:gsub('\\', '/')] ~= nil
            end,
            listdir=function(path)
                return directories[path:gsub('\\', '/')]
            end,
        }
        assert.same({'tests/automation/a_spec.lua',
            'tests/automation/ordinary_spec.lua'},
            project.discover('project', filesystem,
                'tests/automation/*.lua'))
        assert.same({'tests/automation/integration/registered_spec.lua'},
            project.discover('project', filesystem,
                'tests/automation/integration/*.lua'))
    end)
end)

describe('DwarfSpec CLI selection', function()
    local output
    local errors
    local filesystem
    local invoked
    local context
    local files
    local directories
    local modules

    before_each(function()
        output = stream()
        errors = stream()
        invoked = nil
        files = {
            ['project/tests/automation/a_spec.lua']=true,
            ['project/tests/automation/ordinary_spec.lua']=true,
            ['project/tests/automation/integration/registered_spec.lua']=true,
        }
        directories = {
            project={'tests'},
            ['project/tests']={'automation'},
            ['project/tests/automation']={'a_spec.lua', 'ordinary_spec.lua',
                'integration'},
            ['project/tests/automation/integration']={'registered_spec.lua'},
        }
        modules = {}
        filesystem = {
            isfile=function(path) return files[path:gsub('\\', '/')] end,
            isdir=function(path)
                return directories[path:gsub('\\', '/')] ~= nil
            end,
            listdir=function(path)
                return directories[path:gsub('\\', '/')]
            end,
            currentdir=function() return 'project' end,
        }
        context = {
            package_root='.',
            current_directory='project',
            filesystem=filesystem,
            output=output,
            errors=errors,
            loadfile=function(path)
                local result = modules[path:gsub('\\', '/')]
                if result == nil then return nil, 'missing synthetic module' end
                return function() return result end
            end,
            runner={
                run=function(options)
                    invoked = options
                    return {exit_code=0}
                end,
                abort=function(options, run_id)
                    invoked = {options=options, run_id=run_id}
                    return {exit_code=0}
                end,
                status=function(options)
                    invoked = {command='status', options=options}
                    local scheduler = {
                            schema='dwarfspec.scheduler.v2',
                            protocol_version=2,
                            service_instance_id='service-cli-fixture',
                            package_root='D:/Packages/DwarfSpec',
                            package_version='0.2.0',
                            queue={},
                            projects={},
                            quarantine={active=false},
                        }
                    return {exit_code=0, scheduler=scheduler, status={
                        schema='dwarfspec.status.v1',
                        protocol=2,
                        service_loaded=true,
                        scheduler=scheduler,
                    }}
                end,
                recover_executor=function(options, run_id, generation, reason)
                    invoked = {
                        command='recover-executor',
                        options=options,
                        run_id=run_id,
                        generation=generation,
                        reason=reason,
                    }
                    return {exit_code=0, scheduler={
                        schema='dwarfspec.scheduler.v2',
                        protocol_version=2,
                        service_instance_id='service-cli-fixture',
                        package_root='D:/Packages/DwarfSpec',
                        package_version='0.2.0',
                        queue={},
                        projects={},
                        quarantine={active=false},
                    }}
                end,
            },
        }
    end)

    it('prints help without project discovery or runner invocation', function()
        context.filesystem = nil
        assert.equals(0, cli.main({}, context))
        assert.matches('Usage:', output.text, 1, true)
        assert.is_nil(invoked)
    end)

    it('uses identical ordered selections for list and run', function()
        local expression = 'tests/automation/*.lua'
        assert.equals(0, cli.main({'list', expression,
            '--test-glob=tests/automation/*.lua'}, context))
        local listed = output.text
        output.text = ''
        assert.equals(0, cli.main({'run', expression,
            '--test-glob=tests/automation/*.lua', '--no-results'}, context))
        assert.same({'tests/automation/a_spec.lua',
            'tests/automation/ordinary_spec.lua'}, invoked.identities)
        assert.equals(ResultPolicy.NONE, invoked.result_policy)
        assert.is_nil(invoked.result_path)
        assert.equals('tests/automation/a_spec.lua\n' ..
            'tests/automation/ordinary_spec.lua\n', listed)
    end)

    it('uses one configurable discovery glob for list and run', function()
        local test_glob = 'tests/automation/integration/*.lua'
        assert.equals(0, cli.main({'list', '--test-glob=' .. test_glob},
            context))
        local listed = output.text
        output.text = ''
        assert.equals(0, cli.main({'run', '--test-glob', test_glob,
            '--no-results'}, context))
        assert.same({'tests/automation/integration/registered_spec.lua'},
            invoked.identities)
        assert.equals(test_glob, invoked.test_glob)
        assert.equals('tests/automation/integration/registered_spec.lua\n',
            listed)
    end)

    it('accepts the discovery glob from the environment', function()
        context.environment = {
            getenv=function(name)
                if name == 'DWARFSPEC_TEST_GLOB' then
                    return 'tests/automation/integration/*.lua'
                end
                return nil
            end,
        }
        assert.equals(0, cli.main({'list'}, context))
        assert.equals('tests/automation/integration/registered_spec.lua\n',
            output.text)
    end)

    it('accepts the discovery glob from project configuration', function()
        local path = 'project/tests/dwarfspec/config.lua'
        files[path] = true
        modules[path] = {
            settings={
                discovery={test_glob='tests/automation/integration/*.lua'},
            },
        }
        assert.equals(0, cli.main({'list'}, context))
        assert.equals('tests/automation/integration/registered_spec.lua\n',
            output.text)
    end)

    it('resolves the default latest-result file beneath the project root',
            function()
        assert.equals(0, cli.main({
            'run', '--test-glob=tests/automation/*.lua',
        }, context))

        assert.equals(ResultPolicy.FILE, invoked.result_policy)
        assert.equals(
            'project/tests/.test-results/dwarfspec/results.json',
            invoked.result_path)
    end)

    it('loads project dotenv values without replacing process variables',
            function()
        files['project/.env'] = true
        context.readfile = function(path)
            assert.equals('project/.env', path:gsub('\\', '/'))
            return 'DFHACK_RUNNER=dotenv/dfhack-run\n' ..
                'DFHACK_ROOT=dotenv/root\n'
        end
        context.environment = {
            getenv=function(name)
                if name == 'DFHACK_ROOT' then return 'process/root' end
                return nil
            end,
        }
        assert.equals(0, cli.main({'run',
            '--test-glob=tests/automation/*.lua'}, context))
        assert.is_nil(invoked.environment.getenv('DFHACK_RUNNER'))
        assert.equals('process/root',
            invoked.environment.getenv('DFHACK_ROOT'))

        context.environment = {getenv=function() return nil end}
        assert.equals(0, cli.main({'run',
            '--test-glob=tests/automation/*.lua'}, context))
        assert.equals('dotenv/dfhack-run',
            invoked.environment.getenv('DFHACK_RUNNER'))
        assert.equals('dotenv/root',
            invoked.environment.getenv('DFHACK_ROOT'))
    end)

    it('loads dotenv runner configuration for abort project roots',
            function()
        files['project/configured/.env'] = true
        directories['project/configured'] = {}
        context.readfile = function(path)
            assert.equals('project/configured/.env', path:gsub('\\', '/'))
            return 'DFHACK_ROOT=dotenv/root\n'
        end
        assert.equals(0, cli.main({'abort', 'active-run',
            '--project-root=configured'}, context))
        assert.equals('active-run', invoked.run_id)
        assert.equals('dotenv/root',
            invoked.options.environment.getenv('DFHACK_ROOT'))
        assert.equals('project/configured', invoked.options.project_root)
    end)

    it('prints read-only scheduler status', function()
        assert.equals(0, cli.main({'status'}, context))
        assert.equals('status', invoked.command)
        assert.matches('SERVICE service-cli-fixture version=0.2.0',
            output.text, 1, true)
        assert.matches('EXECUTOR idle', output.text, 1, true)
        assert.matches('QUARANTINE none', output.text, 1, true)
    end)

    it('forwards exact executor recovery identity and reason', function()
        assert.equals(0, cli.main({
            'recover-executor', 'blocking-run',
            '--generation=4', '--reason=operator verified clean state',
        }, context))
        assert.equals('recover-executor', invoked.command)
        assert.equals('blocking-run', invoked.run_id)
        assert.equals(4, invoked.generation)
        assert.equals('operator verified clean state', invoked.reason)
        assert.matches('QUARANTINE none', output.text, 1, true)
    end)

    it('requires an exact generation for executor recovery', function()
        assert.equals(2, cli.main({
            'recover-executor', 'blocking-run',
        }, context))
        assert.matches('requires %-%-generation', errors.text)
    end)

    it('returns distinct usage and no-match diagnostics', function()
        assert.equals(2, cli.main({'list', 'tests/***/bad'}, context))
        assert.matches('malformed glob:', errors.text, 1, true)
        errors.text = ''
        assert.equals(3, cli.main({'list', 'tests/no-match*'}, context))
        assert.matches('glob matched no DwarfSpec tests:', errors.text,
            1, true)
        errors.text = ''
        assert.equals(2, cli.main({'list', '--timeout=1'}, context))
        assert.matches('unknown option: %-%-timeout', errors.text)
    end)

    it('forwards quoted values and every run control without tokenizing them',
            function()
        assert.equals(0, cli.main({
            'run', 'tests/automation/*',
            '--test-glob=tests/automation/*.lua',
            '--filter', 'name with spaces', '--filter-out=legacy',
            '--name=exact example', '--tag=fast', '--exclude-tag=slow',
            '--repeat=2',
            '--timeout=12.5', '--queue-timeout=45',
            '--poll-interval-ms=25',
            '--results=result directory', '--run-id=quoted-run', '--verbose',
        }, context))
        assert.same({'name with spaces'}, invoked.filters)
        assert.same({'legacy'}, invoked.filter_out)
        assert.same({'exact example'}, invoked.names)
        assert.same({'fast'}, invoked.tags)
        assert.same({'slow'}, invoked.exclude_tags)
        assert.equals(2, invoked.repeat_count)
        assert.equals(12.5, invoked.timeout_seconds)
        assert.equals(45, invoked.queue_timeout_seconds)
        assert.equals('project/result directory', invoked.result_path)
        assert.equals('quoted-run', invoked.run_id)
        assert.is_true(invoked.verbose)
    end)

    it('accepts an explicitly unlimited queue wait', function()
        assert.equals(0, cli.main({
            'run', 'tests/automation/*',
            '--test-glob=tests/automation/*.lua',
            '--queue-timeout=unlimited',
            '--no-results',
        }, context))
        assert.is_nil(invoked.queue_timeout_seconds)
        assert.equals(ResultPolicy.NONE, invoked.result_policy)
    end)
end)
