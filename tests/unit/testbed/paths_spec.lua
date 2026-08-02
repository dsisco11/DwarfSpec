local config = require('dwarfspec.testbed.config')
local paths = require('dwarfspec.testbed.paths')
local lfs = require('lfs')

---Creates one empty temporary directory and removes the temporary file first.
---@return string
local function temporary_directory()
    local directory = os.tmpname()
    os.remove(directory)
    assert(lfs.mkdir(directory))
    return directory:gsub('\\', '/')
end

---Creates a directory hierarchy for one relative path.
---@param root string
---@param relative string
local function mkdirs(root, relative)
    local current = root
    for segment in relative:gmatch('[^/]+') do
        current = current .. '/' .. segment
        if not lfs.attributes(current, 'mode') then assert(lfs.mkdir(current)) end
    end
end

---Writes one fixture file beneath a temporary directory.
---@param root string
---@param relative string
local function write_file(root, relative)
    local parent = relative:match('^(.*)/[^/]+$')
    if parent then mkdirs(root, parent) end
    local file = assert(io.open(root .. '/' .. relative, 'wb'))
    file:write('-- fixture\n')
    file:close()
end

---Removes a fixture directory tree after one test.
---@param root string
local function remove_tree(root)
    for entry in lfs.dir(root) do
        if entry ~= '.' and entry ~= '..' then
            local path = root .. '/' .. entry
            local attributes = assert(lfs.attributes(path))
            if attributes.mode == 'directory' then
                remove_tree(path)
            else
                assert(os.remove(path))
            end
        end
    end
    assert(lfs.rmdir(root))
end

---Builds normalized configuration with every supplied root treated as existing.
---@param input table|nil
---@param consumer_root string
---@return table
local function normalized(input, consumer_root)
    return config.normalize(input, {consumer_root=consumer_root,
        directory_exists=function() return true end})
end

describe('TestBed paths', function()
    it('builds isolated default module templates in fixed order', function()
        local root = temporary_directory()
        local original_path = package.path
        local resolver = paths.Paths.new(normalized(nil, root))

        assert.same({root .. '/src/scripts_modinstalled', root .. '/src', root},
            resolver.module_roots)
        assert.same({root .. '/src/scripts_modinstalled'}, resolver.script_roots)
        assert.equals(table.concat({
            root .. '/src/scripts_modinstalled/?.lua',
            root .. '/src/scripts_modinstalled/?/init.lua',
            root .. '/src/?.lua', root .. '/src/?/init.lua',
            root .. '/?.lua', root .. '/?/init.lua',
        }, package.config:sub(3, 3)), resolver.package_path)
        assert.equals(original_path, package.path)
        remove_tree(root)
    end)

    it('uses fixed module precedence and reports its normalized source', function()
        local root = temporary_directory()
        write_file(root, 'first/duplicate.lua')
        write_file(root, 'second/duplicate.lua')
        write_file(root, 'second/nested/init.lua')
        local resolver = paths.Paths.new(normalized({module_roots={'first', 'second'}}, root))

        assert.equals(root .. '/first/duplicate.lua', resolver:find_module('duplicate'))
        assert.equals(root .. '/second/nested/init.lua', resolver:find_module('nested'))
        remove_tree(root)
    end)

    it('keeps private path replacement local to later resolver lookups', function()
        local root = temporary_directory()
        write_file(root, 'first/value.lua')
        write_file(root, 'second/value.lua')
        local resolver = paths.Paths.new(normalized({module_roots={'first'}}, root))
        local replacement = root .. '/second/?.lua'

        assert.equals(root .. '/first/value.lua', resolver:find_module('value'))
        resolver.package_path = replacement
        assert.equals(root .. '/second/value.lua', resolver:find_module('value'))
        assert.equals(replacement, resolver.package_path)
        remove_tree(root)
    end)

    it('keeps explicit and empty root replacements exact', function()
        local root = temporary_directory()
        local explicit = paths.Paths.new(normalized({module_roots={'../outside'},
            script_roots={}}, root))
        local provider_only = paths.Paths.new(normalized({module_roots={}, script_roots={}}, root))

        assert.same({root:match('^(.*)/[^/]+$') .. '/outside'}, explicit.module_roots)
        assert.equals('', provider_only.package_path)
        assert.is_nil(provider_only:find_module('missing'))
        local _, message = provider_only:find_module('missing')
        assert.matches('consumer root', message)
        assert.is_not_nil(message:find(root, 1, true))
        assert.matches("no file", message)
        remove_tree(root)
    end)

    it('resolves scripts separately and reports all attempted candidates', function()
        local root = temporary_directory()
        write_file(root, 'scripts/internal/worker.lua')
        write_file(root, 'module/internal/worker.lua')
        local resolver = paths.Paths.new(normalized({module_roots={'module'},
            script_roots={'scripts'}}, root))

        assert.equals(root .. '/scripts/internal/worker.lua',
            resolver:find_script('internal/worker'))
        local result, message = resolver:find_script('missing')
        assert.is_nil(result)
        assert.matches('missing', message)
        assert.matches('scripts', message)
        assert.matches('missing.lua', message)
        remove_tree(root)
    end)

    it('uses the supplied consumer root for relative roots and source paths', function()
        local resolver = paths.Paths.new(normalized({module_roots={'src'},
            script_roots={'scripts'}}, 'consumer'), {
            current_directory=function() return '/work' end,
            file_exists=function() return false end,
        })

        assert.same({'/work/consumer/src'}, resolver.module_roots)
        assert.same({'/work/consumer/scripts'}, resolver.script_roots)
        assert.equals('/work/consumer/fakes/module.lua',
            resolver:resolve_source('fakes/module.lua'))
        assert.equals('/external/fake.lua', resolver:resolve_source('/external/fake.lua'))
        assert.equals('/work/elsewhere/fake.lua',
            resolver:resolve_source('../elsewhere/fake.lua'))
    end)

    it('implements compatible explicit-path search without containment checks', function()
        local seen = {}
        local resolver = paths.Paths.new(normalized({module_roots={}}, '/consumer'), {
            file_exists=function(filename)
                table.insert(seen, filename)
                return filename == '/outside/pkg/name.lua'
            end,
        })

        assert.equals('/outside/pkg/name.lua', resolver:searchpath('pkg.name',
            '/outside/?.lua'))
        assert.same({'/outside/pkg/name.lua'}, seen)
    end)
end)
