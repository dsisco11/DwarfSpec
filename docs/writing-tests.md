# Writing live tests

Live specs can load ordinary consumer-project modules with standard Lua
`require(...)` names. DwarfSpec adds the project root to the in-process module
search path for the duration of each run, so this project layout:

```text
tests/
  support/
    fixtures.lua
  widgets/
    settings.ds.lua
```

can be used from `settings.ds.lua` as follows:

```lua
local fixtures = require('tests.support.fixtures')
```

Project modules loaded during a run are removed from Lua's module cache during
cleanup, preventing stale support code from leaking into a later run.

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

Every mount uses a deterministic 128 by 64 viewport in DF cells unless the
test supplies `viewport={width=..., height=...}`. The default approximates a
1024 by 768 display when DFHack cells are 8 by 12 pixels. Change the current
mounted component later with `ds.viewport(width, height)`; it waits for the
resulting render before returning.

## Component subjects

`ds.mount(component, options)` establishes the test's one implicit current
mount and returns a subject for its root. `ds.get(control_path)` returns another
subject by walking direct children from that root. A path such as
`form/editor` selects `editor` only when it is a direct child of `form`, and
`form` is a direct child of the mounted component. DwarfSpec never performs a
global descendant-ID search. Calling either public mount entry point again
while the mount remains current is an error; call `ds.unmount()` before
mounting another component or attaching to the current native screen.

Every path segment is an exact `view_id`. `/` is reserved as the separator;
paths cannot start or end with `/`, contain empty segments, `.` or `..`, or
cross an anonymous control. Assign a `view_id` to every parent control that a
test must traverse. `ds.root()` is the only way to select the mounted component
itself. A parent cannot contain two direct children with the same `view_id`.

```lua
ds.mount(MyComponent, {value='draft'})
ds.get('editor'):click():type('saved')
ds.get('submit'):click()

local state = ds.get('status'):inspect()
assert.equals('saved', state.text)
assert.equals('saved', ds.get('status'):text())
```

Commands execute immediately in the live test coroutine. `click`, `hover`,
`move_pointer`, `input`, `type`, and `redraw` preserve and return their
subject for chaining. `inspect` returns a stable diagnostic table, while
`text` returns the inspected text scalar. No current subject command changes
the selection; call `ds.get` to obtain a different subject. A subject is valid
only while its original mount remains current; unmounting that mount makes the
subject stale.

`subject:redraw()` requests a repaint of the mount's interaction screen. It
waits for render instrumentation to confirm a later completed render before
returning, so assertions after it observe the requested repaint:

```lua
local panel = ds.get('panel')
panel:redraw()
assert.is_true(panel:inspect().visible)
```

DFHack invalidates the containing screen rather than an individual widget
rectangle. The subject identifies and validates the owning mount; it does not
limit the repaint to that subject. Use `subject:redraw({wait=false})` only
when the test intentionally needs to request the repaint without waiting for
its completion.

For mouse input that must use an already positioned pointer, call
`ds.mouseInput(input)`. The input must be one of the immutable
`ds.EMouseButton` identifiers:

```lua
ds.get('route_list'):hover()
ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)
ds.mouseInput(ds.EMouseButton.RIGHT)
```

Each left, right, and middle button exposes explicit `CLICK`, `DOWN`, and `UP`
actions through the immutable `ds.EInputState` enum. The state defaults to
`CLICK` when omitted for a physical button. A `DOWN` state remains held across
pointer movement and later commands until the matching `UP` input or run
cleanup:

```lua
ds.get('slider'):move_pointer('top_left')
ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.DOWN)
ds.get('slider'):move_pointer('top_right')
ds.mouseInput(ds.EMouseButton.LEFT, ds.EInputState.UP)
```

Unlike `subject:click()`, `ds.mouseInput()` does not move the pointer. It sends
the selected button or wheel input at the position established by
`subject:hover()` or `subject:move_pointer()`.

### Choosing pointer coordinates

Pointer coordinates can use either zero-based UI-grid cells or zero-based
screen pixels:

```lua
ds.move_pointer(17, 9) -- UI-grid cells are the default
ds.move_pointer(17, 9, ds.EPointerSpace.GRID)
ds.move_pointer(640, 360, ds.EPointerSpace.PIXELS) -- exact screen pixel
```

Use UI-grid cells for UI widgets and text-mode screen locations. Subjects and
their `center`, corner, and edge anchors are always resolved in UI-grid cells,
so fluent `subject:move_pointer()` and `subject:hover()` do not accept a
coordinate-space argument.

Use screen pixels when Premium map interaction must target an exact rendered
location. A map tile is not a UI-grid cell or a screen pixel; map-view
coordinates such as `ds.getViewPos()` describe map tiles and are not accepted
as pointer coordinates.

DwarfSpec reads the effective renderer geometry for every pointer move. This
tracks runtime UI-scale, resolution, and window changes; a configured scaling
preference is not treated as the current conversion geometry. Grid input is
paired with the selected cell's center pixel, while pixel input remains exact
and is paired with its derived grid cell. Mouse input resynchronizes the pair,
and cleanup automatically restores both coordinate representations.

`subject:raw()` exposes the underlying object for an exceptional API that
DwarfSpec does not model. It returns a Lua table for a Lua-view subject and
typed DF userdata for a native widget subject. Both are borrowed references
whose lifetime is bounded by the mount. Normal selection, interaction,
inspection, capture, synchronization, and assertions do not require this
escape hatch.

Mount-scoped evidence also uses the implicit context. For example,
`ds.capture_view_tree('before-submit')` captures the current component root;
callers do not pass a root or screen.

## Borrowed native game screens

Call `ds.mountNativeScreen()` to create a native-screen mount for the current
native DF viewscreen. Its implementation uses a non-owning native attachment:
DwarfSpec does not create or show a `ZScreen`, change DFHack focus, alter the
screen stack, or dismiss the borrowed screen. The returned root subject wraps
the exact native widget container exposed by the current viewscreen.

By contrast, `ds.mount(component, options)` creates an owned component mount.
Both commands share one current mount and are released with `ds.unmount()`.
`ESubjectSource` chooses native or registered-overlay subject hierarchies only
after a native-screen mount exists; it does not choose how to mount.

DFHack exposes many base-game controls as typed native widget objects. For
those objects, DwarfSpec can traverse direct children, inspect names, types,
bounds, visibility, activity, supported text, and selected or scroll state.
Some base-game interfaces still draw controls procedurally without exposing
widget nodes. Their rendered cells can appear in a screen capture, but they
cannot be selected by `ds.get()` merely because text or pixels are visible.

`subject:inspect()` keeps the common bounded fields and may add
`native_type`, `name`, `effective_visible`, `effective_active`,
`scroll_position`, `visible_row_count`, and `selected_index` when applicable.
It does not expose an unbounded map of native fields or invoke arbitrary widget
callbacks.

`ds.root()` always wraps the exact borrowed `viewscreen.widgets` container
when called without options. Direct viewscreen-widget paths remain strict:
a string selects one named child, and a segment array supports nested widget
names, zero-based child indices, and widget names containing `/`:

```lua
local native_root = ds.mountNativeScreen()
local tooltip = ds.get('Tooltip')

assert.equals(native_root:raw(), ds.root():raw())
assert.is_userdata(tooltip:raw())
```

Many base-game controls are rooted under
`df.global.game.main_interface` instead of `viewscreen.widgets`. Full game-UI
paths are the common API for those controls; no source option is required:

```lua
ds.input('D_UNITLIST')

local deceased = ds.get({
    'info',
    'creatures',
    'Tabs',
    'Dead/Missing',
})
```

The leading `info` and `creatures` segments name declared DF structure fields.
At `creatures`, `Tabs` is not a declared field and the current value is a
`df.widget_container`, so DwarfSpec switches permanently to exact native
widget traversal. A later widget name is never reinterpreted as a DF field.

The live acceptance suite uses the same rule to reach a real Residents
list row:

```lua
local row_index = 0
local resident = ds.get({
    'info',
    'creatures',
    'Tabs',
    'Residents',
    0,
    'Unit List',
    1,
    row_index,
})

assert.is_userdata(resident:raw())
assert.is_table(resident:inspect().body)
```

Without `native_root`, a native `ds.get()` preserves compatibility by
attempting the exact path from `viewscreen.widgets` and, when its leading
segment is a declared field, from `df.global.game.main_interface`. One
successful result is returned. Two results with the same native identity are
deduplicated; two different identities produce an explicit ambiguity error
instead of selecting one by visibility, activity, focus, or traversal order.

`native_root` remains an advanced escape hatch for an actual ambiguity or a DF
structure the automatic field traversal does not support. It bypasses both
automatic roots and resolves only from the supplied `df.widget_container`:

```lua
local full_path = {
    'info',
    'creatures',
    'Tabs',
    'Dead/Missing',
}

-- If ds.get(full_path) reports different identities from the automatic roots,
-- select the intended exact root and use its root-relative widget path.
local creatures = df.global.game.main_interface.info.creatures
local deceased = ds.get({'Tabs', 'Dead/Missing'}, {
    native_root=creatures,
})
local tree = ds.capture_view_tree('deceased-controls', {
    native_root=creatures,
})
```

The explicit root changes only subject resolution. Input, mouse input, redraw,
focus validation, and lifetime checks still target the native viewscreen
pinned by `ds.mountNativeScreen()`.

The path array itself uses ordinary one-based Lua array positions; integer
segments after widget traversal begins are zero-based native child indices.
Integers before that transition, empty names, negative or fractional indices,
gaps in the array, ambiguous slash-containing string paths, missing declared
fields, missing widgets, unsupported intermediate field values, and dual-root
ambiguity fail explicitly with bounded diagnostics.

The current Hauling route rows are procedurally rendered from
`df.global.plotinfo.hauling` on the supported DFHack host. They are not native
widget userdata and therefore cannot be returned by `ds.get()`. UI-grid or
screen-pixel coordinates can drive that interface, but do not
constitute widget identity.

An attached native screen can also select an enabled widget from DFHack's live
overlay registry. This source is externally owned and must be named exactly:

```lua
local overlay_options = {
    source=ds.ESubjectSource.OVERLAY,
    overlay='my-plugin/route-panel',
}
local overlay_root = ds.root(overlay_options)
local overlay_button = ds.get('confirm', overlay_options)
local overlay_tree = ds.capture_view_tree('route-overlay', overlay_options)
```

Omitting source options, or specifying
`{source=ds.ESubjectSource.NATIVE}`, selects the borrowed native hierarchy.
Source options are not accepted for DwarfSpec-owned component mounts.
Selecting an unknown, disabled, malformed, or non-view overlay fails without
enabling it or changing its registration.
An overlay subject becomes stale if its registered instance is disabled,
removed, or replaced. Overlay subjects expose their Lua view tables through
`subject:raw()`; they do not become native DF userdata.

Native and overlay subjects use the same interaction API. Subject input is
sent through the pinned native viewscreen, while overlay rendering and input
continue through DFHack's normal overlay registry:

```lua
ds.get('menu'):input('SELECT')

ds.move_pointer(17, 9)
ds.mouseInput(ds.EMouseButton.LEFT) -- defaults to EInputState.CLICK
ds.mouseInput(ds.EMouseButton.RIGHT, ds.EInputState.DOWN)
ds.mouseInput(ds.EMouseButton.RIGHT, ds.EInputState.UP)
ds.mouseInput(ds.EMouseButton.SCROLL_DOWN)

ds.get('menu'):move_pointer('center'):click()
ds.redraw()                         -- waits for a completed render
ds.get('menu'):redraw()             -- also waits
ds.redraw(nil, {wait=false})        -- invalidates without waiting
```

Absolute pointer coordinates must be inside the current UI-grid or screen-pixel
bounds for their selected space. DwarfSpec restores the paired pointer and
button state captured at attachment during cleanup. `ds.viewport()` is
intentionally unavailable because DwarfSpec does not own or resize the native
game window.

The attached viewscreen and native widget hierarchy are pinned. If game input,
a script, or another system changes the current viewscreen, subsequent subject
inspection, input, pointer movement, capture, or redraw fails with an explicit
stale-screen error. DwarfSpec never follows the transition or navigates back.
Call `ds.unmount()`, establish the desired game screen, and call
`ds.mountNativeScreen()` again to create a new native attachment.

Attachment also fails explicitly when there is no current native viewscreen,
the viewscreen has no usable widget container, or render observation cannot be
installed. Invalid source options, unresolved paths, unusable subject bounds,
and out-of-window pointer coordinates likewise report the rejected operation
instead of silently falling back to another screen or source.

Cleanup removes DwarfSpec's render observer and retained references, restores
pointer instrumentation and input state, and leaves the borrowed screen,
DFHack focus, screen stack, and external overlay registry intact. In contrast,
component mounts own the component and any DwarfSpec-created host screen and
therefore tear those resources down during unmount.

`subject:getFocusList()` returns a copied list of focus strings for that
subject's current mounted screen. The focus list belongs to the screen, not to
the widget itself, but the call uses normal DwarfSpec subject validation:

```lua
local current_focus = ds.root():getFocusList()
assert.is_true(#current_focus > 0)

local list = ds.get('menu')
assert.same(current_focus, list:getFocusList())
```

## World time

`ds.getTick()` returns the current in-year Dwarf Fortress simulation tick from
`df.global.cur_year_tick`. It is a read-only top-level command and does not
require a mount:

```lua
local tick = ds.getTick()
assert.is_true(tick >= 0)
```

It fails explicitly when no loaded world exposes a valid tick counter.

`ds.getTime()` returns DFHack's current millisecond clock value from
`dfhack.getTickCount()`. It is also read-only and independent of mounting:

```lua
local milliseconds = ds.getTime()
assert.is_true(milliseconds >= 0)
```

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
The mount-owned viewport is applied through reversible instance resize
interception, and `backing_viewscreen` is passed to the screen's normal
`show()` method. `ds.viewport(width, height)` updates that same viewport for
all mounted component categories.

If the component opens a native modal child screen, input follows that child
while it remains above the mounted screen. The implicit component root does
not change: `ds.root()` and `ds.get(control_path)` continue to refer only to
the original mounted screen and its direct-child control tree. A view that
exists only in an unowned child screen is therefore not selected into the
current mount.

## Real overlay registration integration

Normal overlay behavior belongs in isolated component specs named distinctly,
such as `tooltip_overlay_component_spec.ds.lua`. These specs use
`ds.mount(component, options)` and never copy scripts into `hack/scripts/gui`.

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
- components: `mount`, `root`, `get`, `unmount`, `viewport`;
- subjects: `click`, `hover`, `move_pointer`, `input`, `type`, `inspect`,
  `text`, and the exceptional `raw` escape hatch;
- positioned mouse input: `mouseInput` with `EMouseButton` and
  `EInputState`;
- evidence: `capture_view_tree`, `capture_screen`; and
- real registration integration: `stage_overlay_registration`.

Input commands perform their own required render or frame synchronization.
Cleanup and render-generation waiting are internal lifecycle details rather
than public commands.
