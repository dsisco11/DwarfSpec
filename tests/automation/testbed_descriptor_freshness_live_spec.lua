-- Live proof for fresh state across consecutive TestBed descriptor mounts.

local TestBedLiveFixture = require(
    'tests.automation.support.testbed_live_fixture').TestBedLiveFixture
local source = TestBedLiveFixture.source_evidence(ds)

describe(('TestBed descriptor freshness [public=%s internal=%s]')
        :format(source.public, source.internal), function()
    local fixture

    before_each(function()
        fixture = TestBedLiveFixture.new(assert)
    end)

    after_each(function()
        pcall(ds.unmount)
    end)

    it('creates fresh component, module, and script identities', function()
        fixture:assert_active_source(ds)
        local first = fixture:mount(ds, 'Widget'):raw()
        local first_class = getmetatable(first)
        local first_module = first.module_identity
        local first_script = first.script_identity
        ds.unmount()
        fixture:assert_clean(ds)

        local second = fixture:mount(ds, 'Widget'):raw()
        assert.is_not.equals(first_class, getmetatable(second))
        assert.is_not.equals(first_module, second.module_identity)
        assert.is_not.equals(first_script, second.script_identity)
        assert.equals(fixture.module_value, second.module_replacement)
        assert.equals(fixture.script_value, second.script_replacement)
        ds.unmount()
        fixture:assert_clean(ds)
    end)
end)
