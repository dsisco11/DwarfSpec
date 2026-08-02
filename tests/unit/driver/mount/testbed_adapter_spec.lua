-- Driver TestBed adapter contracts.

local adapter = require('dwarfspec.driver.mount.testbed_adapter')
local lfs = require('lfs')

---Creates an empty temporary consumer root.
---@return string
local function temporary_directory()
    local directory = os.tmpname()
    os.remove(directory)
    assert(lfs.mkdir(directory))
    return directory:gsub('\\', '/')
end

---Writes one source fixture below a temporary consumer root.
---@param root string
---@param relative string
---@param content string
local function write_file(root, relative, content)
    local parent = relative:match('^(.*)/[^/]+$')
    if parent and not lfs.attributes(root .. '/' .. parent) then
        assert(lfs.mkdir(root .. '/' .. parent))
    end
    local file = assert(io.open(root .. '/' .. relative, 'wb'))
    file:write(content)
    file:close()
end

---Removes one temporary fixture root.
---@param root string
local function remove_tree(root)
    for entry in lfs.dir(root) do
        if entry ~= '.' and entry ~= '..' then
            assert(os.remove(root .. '/' .. entry))
        end
    end
    assert(lfs.rmdir(root))
end

---Builds one active run and explicit live-host input double.
---@return table, table, table
local function runtime()
    local calls = {}
    local run = {project_root='.'}
    local host = {
        base={run_command=function() return 'host effect' end},
        dfhack={},
        require=function(name)
            table.insert(calls, {kind='module', name=name})
            return {kind='module', name=name}
        end,
        reqscript=function(name)
            table.insert(calls, {kind='script', name=name})
            return {kind='script', name=name}
        end,
    }
    return run, host, calls
end

describe('TestBed mount adapter', function()
    it('supplies only the documented synthesized host modules', function()
        local run, host, calls = runtime()
        local bed = adapter.new(nil, run, host)

        for _, name in ipairs(adapter.COMPONENT_MODULES) do
            assert.equals(name, bed:require(name).name)
        end
        assert.has_error(function() bed:require('plugins.overlay') end)
        assert.same({
            {kind='module', name='class'}, {kind='module', name='utils'},
            {kind='module', name='gui'}, {kind='module', name='gui.widgets'},
            {kind='module', name='gui.dwarfmode'},
        }, calls)
        bed:close()
    end)

    it('allows explicit disablement and user replacement of synthesized tokens', function()
        local run, host, calls = runtime()
        local replacement = {replacement=true}
        local disabled = adapter.new({component_imports=false}, run, host)
        local overridden = adapter.new({imports={{provide={kind='module',
            name='class'}, use_value=replacement}}}, run, host)

        assert.has_error(function() disabled:require('gui') end)
        assert.equals(replacement, overridden:require('class'))
        assert.equals('utils', overridden:require('utils').name)
        assert.same({{kind='module', name='utils'}}, calls)
        disabled:close()
        overridden:close()
    end)

    it('validates explicit live construction inputs', function()
        assert.has_error(function() adapter.new(nil, {}, {}) end)
    end)

    it('forwards the active consumer root and live facade identities', function()
        local root = temporary_directory()
        write_file(root, 'probe.lua', 'return {effect=run_command(), identity=dfhack.identity}')
        local run, host = runtime()
        local identity = {}
        run.project_root = root
        host.base = {run_command=function() return 'host effect' end}
        host.dfhack = {identity=identity}
        local bed = adapter.new({module_roots={'.'}}, run, host)
        local probe = bed:require('probe')

        assert.equals('host effect', probe.effect)
        assert.equals(identity, probe.identity)
        bed:close()
        remove_tree(root)
    end)

    it('takes construction-time snapshots of the supplied live facades', function()
        local root = temporary_directory()
        write_file(root, 'probe.lua', 'return {base=late_base, dfhack=dfhack.late_dfhack}')
        local run, host = runtime()
        run.project_root = root
        local bed = adapter.new({module_roots={'.'}}, run, host)
        host.base.late_base = true
        host.dfhack.late_dfhack = true

        assert.same({base=nil, dfhack=nil}, bed:require('probe'))
        bed:close()
        remove_tree(root)
    end)

    it('uses exact separate host loaders for module and script providers', function()
        local run, host, calls = runtime()
        local bed = adapter.new({imports={{provide={kind='script', name='probe'},
            use_host=true}}}, run, host)

        assert.equals('module', bed:require('class').kind)
        assert.equals('script', bed:reqscript('probe').kind)
        assert.same({{kind='module', name='class'},
            {kind='script', name='probe'}}, calls)
        bed:close()
    end)

    it('maps the declared compatibility version to exactly its provider set', function()
        assert.equals('53.15-r2', adapter.SUPPORTED_DFHACK_VERSION)
        assert.same({'class', 'utils', 'gui', 'gui.widgets', 'gui.dwarfmode'},
            adapter.COMPONENT_IMPORTS_BY_VERSION[adapter.SUPPORTED_DFHACK_VERSION])
    end)

    it('does not load the driver adapter through the standalone public entry point', function()
        local adapter_name = 'dwarfspec.driver.mount.testbed_adapter'
        local testbed_name = 'dwarfspec.testbed'
        local saved_adapter, saved_testbed = package.loaded[adapter_name],
            package.loaded[testbed_name]
        package.loaded[adapter_name], package.loaded[testbed_name] = nil, nil

        require(testbed_name)
        assert.is_nil(package.loaded[adapter_name])

        package.loaded[adapter_name], package.loaded[testbed_name] =
            saved_adapter, saved_testbed
    end)
end)
