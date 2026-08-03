-- Direct behavioral contracts for DwarfSpec command-line parsing.

local command_line = require('dwarfspec.controller.command_line')

describe('DwarfSpec command line', function()
    it('constructs general and command-specific help documents', function()
        assert.matches('DwarfSpec 0%.2%.2', command_line.help())
        for _, topic in ipairs({
                'list', 'run', 'status', 'history', 'show', 'logs', 'abort',
                'recover-executor'}) do
            assert.matches('Usage: dwarfspec ' .. topic,
                command_line.help(topic), 1, true)
        end
        assert.has_error(function() command_line.help('missing') end,
            'unknown help topic: missing')
    end)

    it('returns stable request shapes for every command', function()
        assert.same({command='help'}, command_line.parse({}, 'package'))
        assert.same({command='help', topic='run'},
            command_line.parse({'help', 'run'}, 'package'))
        assert.same({command='version'},
            command_line.parse({'version'}, 'package'))

        local list = command_line.parse({'list', 'tests/**'}, 'package')
        assert.equals('list', list.command)
        assert.equals('tests/**', list.selection)
        assert.equals('package', list.options.package_root)

        local run = command_line.parse({'run'}, 'package')
        assert.equals('run', run.command)
        assert.is_nil(run.selection)

        for _, name in ipairs({'status', 'history'}) do
            local request = command_line.parse({name}, 'package')
            assert.equals(name, request.command)
            assert.is_nil(request.run_id)
        end
        for _, name in ipairs({'show', 'logs', 'abort'}) do
            local request = command_line.parse({name, 'run-id'}, 'package')
            assert.equals(name, request.command)
            assert.equals('run-id', request.run_id)
        end
        local recovery = command_line.parse({
            'recover-executor', 'run-id', '--generation=4',
        }, 'package')
        assert.equals('run-id', recovery.run_id)
        assert.equals(4, recovery.options.generation)
    end)

    it('normalizes every run option without tokenizing values', function()
        local request = command_line.parse({
            'run', '--project-root=consumer root',
            '--test-glob=tests/**/*.lua', '--runner=dfhack runner',
            '--filter=name one', '--filter=name two', '--filter-out=old',
            '--name=exact name', '--tag=fast', '--exclude-tag=slow',
            '--repeat=2', '--timeout=12.5', '--queue-timeout=45',
            '--poll-interval-ms=25', '--startup-delay-frames=2',
            '--lease-timeout-ms=6000', '--lease-check-frames=31',
            '--results=result file.json', '--run-id=safe.run-1', '--verbose',
            'tests/automation/**',
        }, 'package')
        local options = request.options
        assert.equals('tests/automation/**', request.selection)
        assert.equals('consumer root', options.project_root)
        assert.equals('tests/**/*.lua', options.test_glob)
        assert.equals('dfhack runner', options.runner)
        assert.same({'name one', 'name two'}, options.filters)
        assert.same({'old'}, options.filter_out)
        assert.same({'exact name'}, options.names)
        assert.same({'fast'}, options.tags)
        assert.same({'slow'}, options.exclude_tags)
        assert.equals(2, options.repeat_count)
        assert.equals(12.5, options.timeout_seconds)
        assert.equals(45, options.queue_timeout_seconds)
        assert.equals(25, options.poll_interval_ms)
        assert.equals(2, options.startup_delay_frames)
        assert.equals(6000, options.lease_timeout_ms)
        assert.equals(31, options.lease_check_frames)
        assert.equals('result file.json', options.result_path)
        assert.equals('safe.run-1', options.run_id)
        assert.is_true(options.verbose)
    end)

    it('applies defaults independently to every parse result', function()
        local first = command_line.parse({'run'}, 'first').options
        local second = command_line.parse({'run'}, 'second').options
        table.insert(first.filters, 'mutation')
        assert.same({}, second.filters)
        assert.equals('first', first.package_root)
        assert.equals('second', second.package_root)
        assert.equals(1, second.repeat_count)
        assert.equals(30, second.timeout_seconds)
        assert.is_nil(second.queue_timeout_seconds)
        assert.equals(100, second.poll_interval_ms)
        assert.equals(5000, second.lease_timeout_ms)
        assert.is_false(second.verbose)
    end)

    it('preserves unlimited queues and no-results precedence', function()
        for _, arguments in ipairs({
                {'run', '--queue-timeout=unlimited', '--results=result.json',
                    '--no-results'},
                {'run', '--no-results', '--results=result.json'},
            }) do
            local options = command_line.parse(arguments, 'package').options
            assert.is_nil(options.queue_timeout_seconds)
            assert.is_false(options.result_path)
        end
    end)

    it('rejects syntax, arity, unsupported commands, and invalid values',
            function()
        local cases = {
            {{'help', 'run', 'extra'}, 'help accepts at most one command name'},
            {{'version', 'extra'}, 'version does not accept arguments'},
            {{'missing'}, 'unknown command: missing'},
            {{'list', '--timeout=1'}, 'unknown option: --timeout'},
            {{'list', '--project-root'}, 'command syntax:'},
            {{'list', 'one', 'two'}, 'list accepts at most one glob'},
            {{'status', 'extra'}, 'status does not accept arguments'},
            {{'show'}, 'show requires exactly one run id'},
            {{'recover-executor', 'run'},
                'recover-executor requires --generation'},
            {{'run', '--filter='}, '--filter must not be empty'},
            {{'run', '--test-glob=tests/***/bad'}, 'malformed glob:'},
            {{'run', '--repeat=0'}, '--repeat must be a positive integer'},
            {{'run', '--timeout=0'}, '--timeout must be positive'},
            {{'run', '--queue-timeout=0'},
                '--queue-timeout must be positive'},
            {{'run', '--poll-interval-ms=1.5'},
                '--poll-interval-ms must be a positive integer'},
            {{'run', '--run-id=bad/id'},
                '--run-id contains unsupported characters'},
            {{'recover-executor', 'run', '--generation=0'},
                '--generation must be a positive integer'},
            {{'recover-executor', 'run', '--generation=1', '--reason='},
                '--reason must not be empty'},
        }
        for _, case in ipairs(cases) do
            local ok, message = pcall(command_line.parse, case[1], 'package')
            assert.is_false(ok, table.concat(case[1], ' '))
            assert.matches(case[2], tostring(message), 1, true)
        end
    end)
end)
