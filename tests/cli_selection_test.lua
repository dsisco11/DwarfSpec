-- Unit contracts for canonical identity globs, discovery, and CLI dispatch.

local cli = require('dwarfspec.cli')
local glob = require('dwarfspec.glob')
local project = require('dwarfspec.project')

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
            'tests/a_spec.ds.lua',
            'tests/nested/b_spec.ds.lua',
            'tests/nested/deeper/c_spec.ds.lua',
        }
        assert.same({'tests/a_spec.ds.lua'},
            glob.select(identities, 'tests/*_spec.ds.lua'))
        assert.same(identities,
            glob.select(identities, 'tests/**/*_spec.ds.lua'))
        assert.same({'tests/nested/b_spec.ds.lua'},
            glob.select(identities, 'tests/nested/?_spec.ds.lua'))
        assert.is_false(glob.matches('tests/a_spec.ds.lua',
            'tests/A_spec.ds.lua'))
        assert.is_true(glob.matches('tests/star*_spec.ds.lua',
            'tests/star\\*_spec.ds.lua'))
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
            ['project/tests/a_spec.ds.lua']=true,
            ['project/tests/nested/b_spec.ds.lua']=true,
            ['project/tests/nested/ordinary_spec.lua']=true,
        }
        local directories = {
            project={'tests'},
            ['project/tests']={'nested', 'a_spec.ds.lua'},
            ['project/tests/nested']={'ordinary_spec.lua', 'b_spec.ds.lua'},
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
        assert.same({'tests/a_spec.ds.lua',
            'tests/nested/b_spec.ds.lua'},
            project.discover('project', filesystem))
    end)
end)

describe('DwarfSpec CLI selection', function()
    local output
    local errors
    local filesystem
    local invoked
    local context

    before_each(function()
        output = stream()
        errors = stream()
        invoked = nil
        local files = {
            ['project/tests/a_spec.ds.lua']=true,
            ['project/tests/nested/b_spec.ds.lua']=true,
        }
        local directories = {
            project={'tests'},
            ['project/tests']={'nested', 'a_spec.ds.lua'},
            ['project/tests/nested']={'b_spec.ds.lua'},
        }
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
            runner={
                run=function(options)
                    invoked = options
                    return {exit_code=0}
                end,
                abort=function()
                    return {exit_code=0}
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
        local expression = 'tests/**/*.ds.lua'
        assert.equals(0, cli.main({'list', expression}, context))
        local listed = output.text
        output.text = ''
        assert.equals(0, cli.main({'run', expression,
            '--no-results'}, context))
        assert.same({'tests/a_spec.ds.lua',
            'tests/nested/b_spec.ds.lua'}, invoked.identities)
        assert.equals('tests/a_spec.ds.lua\n' ..
            'tests/nested/b_spec.ds.lua\n', listed)
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
            'run', 'tests/*',
            '--filter', 'name with spaces', '--filter-out=legacy',
            '--name=exact example', '--tag=fast', '--exclude-tag=slow',
            '--repeat=2',
            '--timeout=12.5', '--poll-interval-ms=25',
            '--overlay-fixture=tests/fixture with spaces.lua',
            '--results=result directory', '--run-id=quoted-run', '--verbose',
        }, context))
        assert.same({'name with spaces'}, invoked.filters)
        assert.same({'legacy'}, invoked.filter_out)
        assert.same({'exact example'}, invoked.names)
        assert.same({'fast'}, invoked.tags)
        assert.same({'slow'}, invoked.exclude_tags)
        assert.same({'tests/fixture with spaces.lua'},
            invoked.overlay_fixtures)
        assert.equals(2, invoked.repeat_count)
        assert.equals(12.5, invoked.timeout_seconds)
        assert.equals('result directory', invoked.result_directory)
        assert.equals('quoted-run', invoked.run_id)
        assert.is_true(invoked.verbose)
    end)
end)
