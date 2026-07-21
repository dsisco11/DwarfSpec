-- Unit contracts for product-independent DwarfSpec project resolution.

local project = assert(loadfile(
    'tests/automation/support/project.lua'))()

describe('DwarfSpec project resolution', function()
    local files
    local directories
    local function filesystem()
        local function key(path)
            return path:gsub('\\', '/')
        end
        return {
            isfile=function(path) return files[key(path)] == true end,
            isdir=function(path) return directories[key(path)] ~= nil end,
            listdir=function(path) return directories[key(path)] or {} end,
        }
    end

    before_each(function()
        files = {
            ['project/tests/a.ds.lua']=true,
            ['project/tests/nested/z_spec.ds.lua']=true,
            ['project/tests/nested/helper.lua']=true,
            ['project/tests/nested/cover.fixture.lua']=true,
            ['project/tests/support/external_screen.lua']=true,
            ['project/tests/dwarfspec/config.lua']=true,
            ['project/tests/dwarfspec/commands.lua']=true,
        }
        directories = {
            project={'tests'},
            ['project/tests']={'nested', 'a.ds.lua', 'ordinary_test.lua',
                'dwarfspec', 'support'},
            ['project/tests/nested']={'z_spec.ds.lua', 'helper.lua',
                'cover.fixture.lua'},
            ['project/tests/support']={'external_screen.lua'},
            ['project/tests/dwarfspec']={'commands.lua', 'config.lua'},
            ['project/tests/support']={'external_screen.lua'},
        }
    end)

    it('discovers every deterministic nested .ds.lua file', function()
        local descriptor = project.new('project', 'package', filesystem())
        assert.same({'a.ds.lua', 'nested/z_spec.ds.lua'},
            project.discover_specs(descriptor))
    end)

    it('excludes conventional fixture and support files by default', function()
        local descriptor = project.new('project', 'package', filesystem())
        local discovered = project.discover_specs(descriptor)
        assert.same({'a.ds.lua', 'nested/z_spec.ds.lua'}, discovered)
        assert.is_nil(discovered['nested/cover.fixture.lua'])
        assert.is_nil(discovered['support/external_screen.lua'])
    end)

    it('applies custom canonical discovery globs at every depth', function()
        files['project/tests/nested/helper.lua'] = true
        local descriptor = project.new('project', 'package', filesystem())
        assert.same({'nested/helper.lua'}, project.discover_specs(descriptor,
            'tests/nested/helper.lua'))
    end)

    it('discovers optional configuration modules in stable order', function()
        local descriptor = project.new('project', 'package', filesystem())
        assert.same({'tests/dwarfspec/config.lua',
            'tests/dwarfspec/commands.lua'},
            project.discover_config_modules(descriptor))
    end)

    it('rejects paths that escape the declared project root', function()
        assert.has_error(function() project.relative_path('../outside.lua') end,
            'project-relative path must not escape its root: ../outside.lua')
        assert.has_error(function() project.relative_path('C:/outside.lua') end,
            'project-relative path must not escape its root: C:/outside.lua')
    end)
end)
