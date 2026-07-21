# Writing live tests

DwarfSpec recursively discovers files whose basenames match `*.ds.lua` beneath
`tests/` by default. This keeps live tests separate from ordinary Busted unit
specs while preserving normal Busted `describe`, `it`, hooks, and Luassert
assertions. Consumers can set `settings.discovery.test_glob` in
`tests/dwarfspec/config.lua`, use `DWARFSPEC_TEST_GLOB`, or pass `--test-glob`
when another naming convention is more appropriate.

The default `*.ds.lua` discovery glob selects live specs only. Reusable
factories and data builders remain ordinary Lua modules that tests import
explicitly. DwarfSpec privately instruments successful renders and
synchronizes interactions across live DFHack frames.

## Ordinary widget components

Pass a `widgets.Widget` constructor to `ds.mount` when DwarfSpec should create
the component. Non-reserved mount options become constructor attributes. A
live spec imports the component from its production module and runs DwarfSpec
commands inside normal Busted examples.

For example, `tests/components/save_panel_spec.ds.lua` contains the test:

```lua
local SavePanel = require('my_plugin.save_panel')

describe('SavePanel', function()
    it('copies the edited value into the visible status', function()
        ds.mount(SavePanel, {value='draft'})
        ds.get('editor'):click():type('saved')
        ds.get('submit'):click()

        assert.equals('saved', ds.get('status'):text())
    end)

    it('accepts an already-created component instance', function()
        local panel = SavePanel{value='ready'}
        local root = ds.mount(panel, {
            viewport={width=60, height=20},
        })

        assert.equals(panel, root:raw())
    end)
end)
```

The component remains in its own production file,
`src/my_plugin/save_panel.lua`:

```lua
local widgets = require('gui.widgets')

---@class my_plugin.SavePanel: gui.widgets.Panel
local SavePanel = defclass(nil, widgets.Panel)
SavePanel.ATTRS{value=DEFAULT_NIL}

---Builds the editable value and save status.
function SavePanel:init()
    self:addviews{
        widgets.EditField{
            view_id='editor',
            frame={l=0, t=0, w=24},
            text=self.value or '',
        },
        widgets.HotkeyLabel{
            view_id='submit',
            frame={l=0, t=2, w=12},
            label='Save',
            on_activate=self:callback('save'),
        },
        widgets.Label{
            view_id='status',
            frame={l=0, t=4, w=30},
            text='pending',
        },
    }
end

---Copies the current editor value into the visible status.
function SavePanel:save()
    self.subviews.status:setText(self.subviews.editor.text)
end

return SavePanel
```

Pass an already-created instance when setup outside the mount is itself part
of the test. Component attributes cannot be supplied again for an instance;
mount-only options such as the `viewport` shown above remain available.

## Component subjects

`ds.mount(component, options)` establishes the test's one implicit current
mount and returns a subject for its root. `ds.get(view_id)` searches only that
mount's propagated view-id index and returns another subject. Missing and
duplicate ids fail with the requested id and mount identity instead of choosing
an arbitrary view. Calling `ds.mount()` again while the mount remains current
is an error; call `ds.unmount()` before mounting another component.

```lua
ds.mount(MyComponent, {value='draft'})
ds.get('editor'):click():type('saved')
ds.get('submit'):click()

local state = ds.get('status'):inspect()
assert.equals('saved', state.text)
assert.equals('saved', ds.get('status'):text())
```

Commands execute immediately in the live test coroutine. `click`, `hover`,
`move_pointer`, `input`, and `type` preserve and return their subject for
chaining. `inspect` returns a stable diagnostic table, while `text` returns the
inspected text scalar. No current subject command changes the selection; call
`ds.get` to obtain a different subject. A subject is valid only while its
original mount remains current; unmounting that mount makes the subject stale.

`subject:raw()` exposes the underlying DFHack object for an exceptional native
API that DwarfSpec does not model. Normal selection, interaction, inspection,
capture, synchronization, and assertions do not require this escape hatch.

Mount-scoped evidence also uses the implicit context. For example,
`ds.capture_view_tree('before-submit')` captures the current component root;
callers do not pass a root or screen.

## Condition waits

`ds.await(description, query, options)` polls a read-only query between live
DFHack frames until it returns a truthy value. The required description names
the operation in progress and is included in timeout diagnostics.

```lua
local renderer = ds.await('tooltip becomes visible', function()
    local state = ds.tooltip_state()
    return state.screen.renderer.visible and state.screen.renderer
end)
```

The truthy query result is returned to the test. Optional `frame_budget` and
`timeout_ms` values override the project-wide wait settings for one operation.
Use `ds.wait_frames(count)` only when the number of raw DFHack frames is itself
part of the contract.

## Isolated overlay components

Mount an `overlay.OverlayWidget` class or existing instance through the same
component entry point as any other GUI component:

```lua
local overlay = require('plugins.overlay')

local root = ds.mount(MyOverlayWidget, {
    backing_viewscreen=dfhack.gui.getCurViewscreen(true),
    overlay_position={x=4, y=-2},
})
```

An existing overlay instance uses the same operation:

```lua
local overlay_component = MyOverlayWidget{}
ds.mount(overlay_component, {
    backing_viewscreen=dfhack.gui.getCurViewscreen(true),
    overlay_position={x=4, y=-2},
})
```

`overlay_position` uses DFHack's one-based overlay coordinates. Positive
values anchor from the left or top, while negative values anchor from the
right or bottom. The position is local to the mount and is never read from or
written to persisted overlay configuration. If the component has no `name`,
DwarfSpec assigns a run-owned logical name for the duration of the mount.

The owned host supplies the normal scaled-interface painter, or the full
window painter when `fullscreen=true`. A `full_interface=true` overlay still
uses the scaled-interface painter, matching DFHack. The host also calls
`overlay_onenable`, throttled `overlay_onupdate`, active-and-visible `onInput`,
and `overlay_ondisable` in their normal lifecycle order. The explicit
`backing_viewscreen` is supplied to `overlay_onupdate`.

This isolated component path intentionally bypasses GUI script discovery,
persisted enablement and position, viewscreen and focus filtering, hotspot
registration, overlay database registration, and rescanning. Tests for those
integration behaviors should use the separate overlay-registration support;
they do not require another component mount command.

## Complete screen components

Mount a `gui.ZScreen` class or existing instance with the same entry point:

```lua
local root = ds.mount(MyScreen, {
    backing_viewscreen=dfhack.gui.getCurViewscreen(true),
    viewport={width=80, height=25},
})

ds.get('submit'):click()
assert.equals('saved', ds.get('status'):text())
```

An existing complete screen also uses the same operation and lifecycle:

```lua
local screen = MyScreen{initial_pause=false}
ds.mount(screen, {
    backing_viewscreen=dfhack.gui.getCurViewscreen(true),
})
```

DwarfSpec shows the supplied screen directly and installs reversible render
instrumentation on that instance. Native activation, dismissal, pause
restoration, and parent input forwarding remain the screen's responsibility.
An optional fixed `viewport` is applied through reversible instance resize
interception, and `backing_viewscreen` is passed to the screen's normal
`show()` method.

If the component opens a native modal child screen, input follows that child
while it remains above the mounted screen. The implicit component root does
not change: `ds.root()` and `ds.get(view_id)` continue to refer only to the
original mounted screen and its view descendants. A view that exists only in
an unowned child screen is therefore not selected into the current mount.

## Real overlay registration integration

Normal overlay behavior belongs in isolated component specs named distinctly,
such as `tooltip_overlay_component_spec.ds.lua`. These specs use `ds.mount()`
and never copy scripts into `hack/scripts/gui`.

DwarfSpec retains a separately selected registration integration for the real
DFHack boundary. It proves `OVERLAY_WIDGETS` discovery, registration, rescan,
enablement, persisted positioning, focus filtering, and cleanup. Consumers
with the same integration need can call
`ds.stage_overlay_registration(source_path, logical_name)` from a distinctly
named, explicitly selected integration spec. The source is an ordinary Lua
overlay script, not a component mount or fixture-definition protocol.

The integration support refuses to replace an existing destination or remove
a staged script whose contents changed. It snapshots `dfhack-config/overlay.json`
before registration, disables the staged widgets during cleanup, restores the
configuration artifact byte for byte, removes only its unchanged run-owned
script, performs a final rescan, and verifies that no staged registration
remains. The integration spec is excluded from the normal component-test glob
and must be selected explicitly when validating the DFHack overlay boundary.

## Public commands

The first-release surface is intentionally small:

- synchronization: `await`, `wait_frames`;
- components: `mount`, `root`, `get`, `unmount`, `resize`;
- subjects: `click`, `hover`, `move_pointer`, `input`, `type`, `inspect`,
  `text`, and the exceptional `raw` escape hatch;
- evidence: `capture_view_tree`, `capture_screen`; and
- real registration integration: `stage_overlay_registration`.

Input commands perform their own required render or frame synchronization.
Cleanup and render-generation waiting are internal lifecycle details rather
than public commands.
