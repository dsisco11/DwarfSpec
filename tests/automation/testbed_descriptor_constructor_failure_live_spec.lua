-- Live proof for TestBed cleanup after descriptor construction fails.

local TestBedLiveFixture = require(
    'tests.automation.support.testbed_live_fixture').TestBedLiveFixture
local source = TestBedLiveFixture.source_evidence(ds)

describe(('TestBed descriptor constructor failure [public=%s internal=%s]')
        :format(source.public, source.internal), function()
    local fixture

    before_each(function()
        fixture = TestBedLiveFixture.new(assert)
    end)

    after_each(function()
        pcall(ds.unmount)
    end)

    it('closes the failed bed and leaves the mount host usable', function()
        fixture:assert_active_source(ds)
        local ok, message = pcall(function()
            fixture:mount(ds, 'FailingWidget')
        end)

        assert.is_false(ok)
        assert.matches('intentional TestBed live constructor failure',
            message, 1, true)
        assert.is_true(fixture.probe.constructor_started)
        assert.is_function(fixture.probe.retained_require)
        assert.has_error(function()
            fixture.probe.retained_require('testbed_live.after_close')
        end, 'TestBed is closed')
        fixture:assert_clean(ds)

        fixture:mount(ds, 'Widget')
        assert.equals('pending', ds.get('status'):text())
        ds.unmount()
        fixture:assert_clean(ds)
    end)
end)
