-- TestBed provider-registry behavior through public module and script loading.

local TestBed = require('dwarfspec.testbed')
local fixtures = dofile('tests/unit/testbed/fixture_integrity.lua')

local FIXTURE_ROOT = fixtures.FIXTURE_ROOT
local FixtureIntegrityGuard = fixtures.FixtureIntegrityGuard

describe('TestBed providers', function()
    local fixture_guard

    before_each(function()
        fixture_guard = FixtureIntegrityGuard.new(assert)
    end)

    after_each(function()
        fixture_guard:assert_unchanged()
    end)

    it('keeps module and script token namespaces separate across values, aliases, and sources', function()
        local module_value, script_value = {kind='module value'}, {kind='script value'}
        local bed = TestBed.new({imports={
            {provide={kind='module', name='value'}, use_value=module_value},
            {provide={kind='module', name='alias'},
                use_existing={kind='module', name='value'}},
            {provide={kind='module', name='source'},
                use_source=FIXTURE_ROOT .. '/providers/module_source.lua'},
            {provide={kind='script', name='value'}, use_value=script_value},
            {provide={kind='script', name='alias'},
                use_existing={kind='script', name='value'}},
            {provide={kind='script', name='source'},
                use_source=FIXTURE_ROOT .. '/providers/script_source.lua'},
        }, module_roots={}, script_roots={}})

        assert.equals(module_value, bed:require('value'))
        assert.equals(module_value, bed:require('alias'))
        assert.equals('module source', bed:require('source').kind)
        assert.equals(script_value, bed:reqscript('value'))
        assert.equals(script_value, bed:reqscript('alias'))
        assert.equals('script source', bed:reqscript('source').kind)
        bed:close()
    end)
end)
