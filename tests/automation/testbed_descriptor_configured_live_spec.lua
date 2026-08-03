-- Live proof for one configured TestBed descriptor mount.

local TestBedLiveFixture = require(
    'tests.automation.support.testbed_live_fixture').TestBedLiveFixture
local widgets = require('gui.widgets')
local source = TestBedLiveFixture.source_evidence(ds)

describe(('TestBed configured descriptor mount [public=%s internal=%s]')
        :format(source.public, source.internal), function()
    local fixture
    local observer

    before_each(function()
        observer = mock({record=function() end})
        fixture = TestBedLiveFixture.new(assert, observer)
    end)

    after_each(function()
        pcall(ds.unmount)
    end)

    it('loads, interacts, and cleans up through real host providers', function()
        fixture:assert_active_source(ds)
        local root = fixture:mount(ds, 'Widget')
        local component = root:raw()

        assert.equals(widgets.Panel, getmetatable(component).super)
        assert.equals(fixture.module_value, component.module_replacement)
        assert.equals(fixture.script_value, component.script_replacement)
        assert.equals('pending', ds.get('status'):text())
        ds.get('activate'):click()
        assert.equals('active:module replacement:script replacement',
            ds.get('status'):text())
        assert.is_true(spy.is_spy(observer.record))
        assert.spy(observer.record).was.called_with(
            'active:module replacement:script replacement')

        ds.unmount()
        fixture:assert_clean(ds)
    end)
end)
