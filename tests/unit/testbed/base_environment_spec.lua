-- TestBed base-environment construction contracts.

local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
local RESERVED_POLICY = require('dwarfspec.testbed.base_environment').RESERVED_POLICY
local normalize = require('dwarfspec.testbed.config').normalize

---Constructs normalized configuration data sufficient for base-environment tests.
---@param globals? table
---@return table
local function normalized(globals)
    return {globals=globals or {}}
end

describe('TestBed base environment', function()
    it('copies only documented standard bindings into an offline bed', function()
        local environment = BaseEnvironment.new(normalized({replacement='value'}))

        assert.equals(_VERSION, environment.base._VERSION)
        assert.equals('value', environment.base.replacement)
        assert.is_nil(environment.base.nonexistent_process_global)
        assert.is_nil(environment.base.package.path)
    end)

    it('keeps normal base fields bed-owned and protects loader fields', function()
        local environment = BaseEnvironment.new(normalized())
        environment.base.shared = 1
        environment.base.rawset(environment.base, 'second', 2)

        assert.equals(1, environment.base.shared)
        assert.equals(2, environment.base.rawget(environment.base, 'second'))
        assert.has_error(function() environment.base.rawset(environment.base, 'require', false) end,
            'TestBed base.require is loader-owned')
        assert.has_error(function() environment.base.require = false end,
            'TestBed base.require is loader-owned')
        assert.has_error(function() setmetatable(environment.base, {}) end,
            'cannot change a protected metatable')
    end)

    it('iterates facade backing and preserves native wrappers elsewhere', function()
        local environment = BaseEnvironment.new(normalized({visible=true}))
        local observed = {}
        for key, value in environment.base.pairs(environment.base) do observed[key] = value end
        local ordinary = {answer=42}

        assert.is_true(observed.visible)
        assert.equals(42, environment.base.rawget(ordinary, 'answer'))
        assert.equals('answer', environment.base.next(ordinary, nil))
    end)

    it('uses a complete configured dfhack backing with one stable facade', function()
        local host = {timeout='host', missing='host-only'}
        local configured = {timeout='mock'}
        local environment = BaseEnvironment.new(normalized({dfhack=configured}), {host_dfhack=host})

        assert.equals('mock', environment.dfhack.timeout)
        assert.is_nil(environment.dfhack.missing)
        assert.equals(environment.base, environment.dfhack.BASE_G)
        environment.dfhack.added = true
        assert.is_true(environment.dfhack_backing.added)
        assert.is_nil(configured.added)
        assert.is_nil(host.added)
    end)

    it('snapshots live base state once and masks reserved host loader entries', function()
        local host_base = {ordinary='before', require=function() error('host require') end,
            reload=function() error('host reload') end}
        local host_dfhack = {ordinary='api', reload=function() error('host dfhack reload') end}
        local environment = BaseEnvironment.new(normalized(), {host_base=host_base, host_dfhack=host_dfhack})
        host_base.ordinary = 'after'
        host_base.later = true
        host_dfhack.later = true

        assert.equals('before', environment.base.ordinary)
        assert.is_nil(environment.base.later)
        assert.equals('api', environment.dfhack.ordinary)
        assert.is_nil(environment.dfhack.later)
        assert.has_error(function() environment.base.reload() end,
            'TestBed reload is unavailable in this environment')
        assert.has_error(function() environment.dfhack.reload() end,
            'TestBed dfhack.reload is unavailable in this environment')
    end)

    it('accepts later loader closures without delegating unbound operations', function()
        local environment = BaseEnvironment.new(normalized(), {loaders={
            require=function(name) return 'private:' .. name end,
            reqscript=function(name) return {name=name} end,
        }})

        assert.equals('private:widget', environment.base.require('widget'))
        assert.same({name='tool'}, environment.dfhack.reqscript('tool'))
        assert.has_error(function() environment.base.load('return true') end,
            'TestBed load is unavailable in this environment')
        assert.is_nil(environment.base.dfhack_flags)
    end)

    it('uses the published policy for validation, snapshots, and facade protection', function()
        local host_base, host_dfhack = {}, {}
        for key in pairs(RESERVED_POLICY.base) do host_base[key] = 'host sentinel' end
        for key in pairs(RESERVED_POLICY.dfhack) do host_dfhack[key] = 'host sentinel' end
        local environment = BaseEnvironment.new(normalized(), {
            host_base=host_base, host_dfhack=host_dfhack,
        })

        for key in pairs(RESERVED_POLICY.base) do
            assert.has_error(function() environment.base.rawset(environment.base, key, false) end)
            if key ~= 'dfhack' then
                assert.has_error(function() normalize({globals={[key]=false}}) end)
            end
        end
        for key in pairs(RESERVED_POLICY.dfhack) do
            assert.has_error(function() environment.base.rawset(environment.dfhack, key, false) end)
        end
        assert.equals(environment.base, environment.dfhack.BASE_G)
        for key in pairs(RESERVED_POLICY.base) do
            assert.is_false(environment.base[key] == 'host sentinel')
        end
        assert.has_error(function() environment.dfhack.reload() end,
            'TestBed dfhack.reload is unavailable in this environment')
    end)
end)
