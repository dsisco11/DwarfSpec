-- TestBed source-module environment and dynamic-loader contracts.

local TestBedBase = require('dwarfspec.testbed.base_environment')
local BaseEnvironment = TestBedBase.BaseEnvironment
local ModuleEnvironment = TestBedBase.ModuleEnvironment

---Creates a fresh module environment with controlled private loader doubles.
---@return dwarfspec.testbed.ModuleEnvironment, table
local function new_environment()
    local base = BaseEnvironment.new({globals={}}).base
    local calls = {}
    local environment = ModuleEnvironment.new(base, {package={private=true},
        require=function(name) calls.require = name; return 'required:' .. name end,
        reqscript=function(name) calls.reqscript = name; return {name=name} end,
        mkmodule=function(name) calls.mkmodule = name; return {name=name} end,
    })
    return environment, calls
end

describe('TestBed module environment', function()
    it('isolates direct and _G-qualified writes from process globals', function()
        local environment = new_environment()
        local chunk = assert(environment.values.load(
            'direct = 1; _G.qualified = 2; return _G, direct, qualified'))
        local module_global, direct, qualified = chunk()

        assert.equals(environment.values, module_global)
        assert.equals(1, direct)
        assert.equals(2, qualified)
        assert.is_nil(rawget(_G, 'direct'))
        assert.is_nil(rawget(_G, 'qualified'))
    end)

    it('falls back to the base facade and retains injected loader identities', function()
        local environment, calls = new_environment()
        environment.base.from_base = 'base value'
        local chunk = assert(environment.values.load([[
            return from_base, package.private, require('one'), reqscript('two').name,
                mkmodule('three').name
        ]]))
        local base_value, private, required, script, module = chunk()

        assert.equals('base value', base_value)
        assert.is_true(private)
        assert.equals('required:one', required)
        assert.equals('two', script)
        assert.equals('three', module)
        assert.same({require='one', reqscript='two', mkmodule='three'}, calls)
        assert.is_nil(environment.values.dfhack_flags)
    end)

    it('defaults dynamic chunks to the owning environment and honors explicit environments', function()
        local environment = new_environment()
        local owned = assert(environment.values.load('owned = true; return _G'))
        local alternate = {}
        local explicit = assert(environment.values.load('alternate = true; return _G', nil, nil, alternate))

        assert.equals(environment.values, owned())
        assert.is_nil(explicit())
        assert.is_true(environment.values.owned)
        assert.is_nil(environment.values.alternate)
        assert.is_true(alternate.alternate)
        local false_environment = assert(environment.values.load('return _G', nil, nil, false))
        assert.has_error(false_environment)
    end)

    it('returns dynamic syntax and file errors without touching process globals', function()
        local environment = new_environment()
        local chunk, syntax_error = environment.values.load('function')
        local file, file_error = environment.values.loadfile('missing-testbed-file.lua')

        assert.is_nil(chunk)
        assert.is_string(syntax_error)
        assert.is_nil(file)
        assert.is_string(file_error)
        assert.is_nil(rawget(_G, 'missing_testbed_file'))
    end)

    it('runs loadfile and dofile in the owning environment with multiple returns', function()
        local environment = new_environment()
        local filename = os.tmpname()
        local file = assert(io.open(filename, 'w'))
        file:write('from_file = "owned"; return 1, 2, _G')
        file:close()

        local chunk = assert(environment.values.loadfile(filename))
        local first, second, loaded_environment = chunk()
        local alternate = {}
        local explicit = assert(environment.values.loadfile(filename, nil, alternate))
        explicit()
        environment.values.from_file = nil
        local dofile_first, dofile_second, dofile_environment = environment.values.dofile(filename)
        os.remove(filename)

        assert.equals(1, first)
        assert.equals(2, second)
        assert.equals(environment.values, loaded_environment)
        assert.equals(1, dofile_first)
        assert.equals(2, dofile_second)
        assert.equals(environment.values, dofile_environment)
        assert.equals('owned', environment.values.from_file)
        assert.equals('owned', alternate.from_file)
        assert.is_nil(rawget(_G, 'from_file'))
    end)

    it('keeps nested dynamic loading in the owner without changing process paths', function()
        local environment = new_environment()
        local inner = os.tmpname()
        local outer = os.tmpname()
        local inner_file = assert(io.open(inner, 'w'))
        inner_file:write('inner_value = true; return 3, 4, _G')
        inner_file:close()
        local outer_file = assert(io.open(outer, 'w'))
        outer_file:write(([[
            local generated = assert(load('generated_value = true; return _G'))
            local from_loadfile = assert(loadfile(%q))
            local _, _, loaded_environment = from_loadfile()
            local _, _, dofile_environment = dofile(%q)
            return generated(), loaded_environment, dofile_environment
        ]]):format(inner, inner))
        outer_file:close()
        local process_path = package.path
        local chunk = assert(environment.values.loadfile(outer))
        local generated_environment, loaded_environment, dofile_environment = chunk()
        os.remove(inner)
        os.remove(outer)

        assert.equals(environment.values, generated_environment)
        assert.equals(environment.values, loaded_environment)
        assert.equals(environment.values, dofile_environment)
        assert.is_true(environment.values.generated_value)
        assert.is_true(environment.values.inner_value)
        assert.equals(process_path, package.path)
        assert.is_nil(rawget(_G, 'generated_value'))
        assert.is_nil(rawget(_G, 'inner_value'))
    end)
end)
