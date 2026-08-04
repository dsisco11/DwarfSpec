-- TestBed script-loader contracts with in-memory consumer sources.

local ScriptLoader = require('dwarfspec.testbed.script_loader').ScriptLoader
local VirtualFilesystem = dofile('tests/unit/testbed/virtual_filesystem.lua').VirtualFilesystem

---Creates one script-loader state backed entirely by in-memory source text.
---@param sources table<string, string>
---@param providers? table<string, table>
---@return dwarfspec.testbed.ScriptLoader, dwarfspec.testbed.spec.VirtualFilesystem
local function new_loader(sources, providers)
    local filesystem = VirtualFilesystem.new()
    filesystem:add_all(sources)
    local options = filesystem:options()
    local state = {
        base={}, package={}, normalized={provider_registry={script=providers or {}}},
        paths={find_script=function(_, name) return filesystem:resolve(name .. '.lua') end,
            resolve_source=function(_, name) return filesystem:resolve(name) end},
        ensure_open=function() end,
        require=function(_, name) return 'module:' .. name end,
        mkmodule=function(_, name) return {name=name} end,
        set_script_loader=function(self, loader) self.script_loader = loader end,
    }
    return ScriptLoader.new(state, options), filesystem
end

describe('TestBed script loader', function()
    it('loads annotated scripts once and keeps nested reqscript calls private', function()
        local loader = new_loader({
            ['child.lua']='--@ module=true\nvalue = 4',
            ['parent.lua']='--@ module=true\nchild = reqscript("child"); value = child.value + 1',
        })
        local parent = loader:reqscript('parent')

        assert.equals(5, parent.value)
        assert.equals(parent.child, loader:reqscript('child'))
        assert.equals(parent, loader:reqscript('parent'))
    end)

    it('handles provider aliases and retries a failed annotated script', function()
        local supplied = {provider=true}
        local loader, filesystem = new_loader({
            ['retry.lua']='--@ module=true\nerror("first load failed")',
        }, {
            value={use_value=supplied},
            alias={use_existing={name='value'}},
        })

        assert.equals(supplied, loader:reqscript('alias'))
        assert.has_error(function() loader:reqscript('retry') end)
        filesystem:add('retry.lua', '--@ module=true\nretried = true')
        assert.is_true(loader:reqscript('retry').retried)
    end)

    it('bounds an alias-only script cycle without allocating source state', function()
        local loader = new_loader({}, {
            first={use_existing={name='second'}},
            second={use_existing={name='first'}},
        })
        local ok, message = pcall(function() loader:reqscript('first') end)

        assert.is_false(ok)
        assert.is_truthy(message:find(
            'TestBed circular reqscript: first -> second -> first', 1, true))
        assert.is_nil(next(loader.scripts))
        assert.is_nil(next(loader.active))
    end)

    it('rejects legacy annotations and clears its script cache on close', function()
        local loader = new_loader({
            ['legacy.lua']='--@ moduleMode=true\nvalue = true',
            ['value.lua']='--@ module=true\nvalue = true',
        })

        assert.has_error(function() loader:reqscript('legacy') end)
        assert.is_true(loader:reqscript('value').value)
        loader:close()
        assert.is_nil(next(loader.scripts))
        assert.is_nil(loader.read_source)
        assert.is_nil(loader.load_chunk)
        assert.is_nil(loader.loadfile)
    end)
end)
