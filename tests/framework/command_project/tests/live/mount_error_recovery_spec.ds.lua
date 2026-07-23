-- Deliberate command errors followed by live mount leak verification.

local widgets = require('gui.widgets')

---@class tests.CommandRecoveryWidget: widgets.Panel
local CommandRecoveryWidget = defclass(nil, widgets.Panel)
CommandRecoveryWidget.ATTRS{
    frame={w=24, h=5},
}

---Creates one selectable child for failing subject commands.
function CommandRecoveryWidget:init()
    self:addviews{
        widgets.Label{
            view_id='selected',
            frame={l=1, t=1, w=20},
            text='selected',
        },
    }
end

local failed_subject
local failed_screen

---Mounts a component and retains only references used to prove staleness.
local function mount_for_failure()
    failed_subject = ds.mount(CommandRecoveryWidget)
    failed_screen = failed_subject:raw().parent_view
end

---Asserts that the preceding failed example leaked no mounted resources.
local function assert_previous_mount_cleaned()
    local evidence = assert(ds.current_run().last_mount_diagnostics)
    assert.is_false(failed_screen:isActive())
    assert.has_error(function() ds.root() end,
        'DwarfSpec root requires a mounted component; call ' ..
            'ds.mount(component, options) first')
    local available, stale_error = pcall(failed_subject.raw, failed_subject)
    assert.is_false(available)
    assert.matches('no component is currently mounted', stale_error,
        1, true)
    assert.is_true(evidence.tree.capture_bounds.node_count <=
        evidence.tree.capture_bounds.max_nodes)
    assert.is_true(evidence.screen.width <= 16)
    assert.is_true(evidence.screen.height <= 8)
end

describe('mounted command-error recovery', function()
    it('01 fails an interaction while a component is mounted', function()
        mount_for_failure()
        ds.get('selected'):move_pointer('unsupported-anchor')
    end)

    it('02 starts clean after the failed interaction', function()
        assert_previous_mount_cleaned()
    end)

    it('03 times out a wait while a component is mounted', function()
        mount_for_failure()
        ds.await('deliberate mounted wait timeout', function()
            return false
        end, {frame_budget=1, timeout_ms=1000})
    end)

    it('04 starts clean after the timed-out interaction', function()
        assert_previous_mount_cleaned()
    end)
end)
