# Writing live tests

DwarfSpec recursively discovers files whose basenames match `*.ds.lua` beneath
`tests/` by default. This keeps live tests separate from ordinary Busted unit
specs while preserving normal Busted `describe`, `it`, hooks, and Luassert
assertions. Consumers can set `settings.discovery.test_glob` in
`tests/dwarfspec/config.lua`, use `DWARFSPEC_TEST_GLOB`, or pass `--test-glob`
when another naming convention is more appropriate.

Fixtures are explicit project-relative imports:

```lua
local screen = ds.show_fixture(
    'tests/tooltip/fixtures/tooltip.fixture.lua')
```

`tests/**/fixtures/*.fixture.lua` is the recommended co-located convention.
It is not an allowlist or mandatory root. A fixture such as
`tests/support/shared_screen.lua` remains valid when imported explicitly.
Screen fixture modules return a table with `new(options)` and produce a DFHack
screen. DwarfSpec privately instruments successful renders and synchronizes
fixture interactions without requiring fields or hooks in the fixture class.

## Component subjects

`ds.mount(component, options)` establishes the test's one implicit current
mount and returns a subject for its root. `ds.get(view_id)` searches only that
mount's propagated view-id index and returns another subject. Missing and
duplicate ids fail with the requested id and mount identity instead of choosing
an arbitrary view.

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
original mount remains current; unmounting or replacing that mount makes the
subject stale.

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

Overlay fixture definitions are also explicit imports. A definition returns a
safe logical name and a project-relative source file:

```lua
return {
    name='tooltip_probe',
    source='tests/tooltip/fixtures/tooltip_overlay.lua',
}
```

`ds.stage_overlay_fixture(definition_path)` copies the source to a unique
run-owned GUI script name, rescans overlays, and guarantees exact removal and a
final rescan through automatic cleanup. Stage overlays from the spec itself;
the external command has no separate overlay-fixture option.

## Public commands

The first-release surface is intentionally small:

- synchronization: `await`, `wait_frames`;
- components: `mount`, `root`, `get`, `unmount`, `resize`;
- subjects: `click`, `hover`, `move_pointer`, `input`, `type`, `inspect`,
  `text`, and the exceptional `raw` escape hatch;
- fixtures: `show_fixture`, `dismiss`, `stage_overlay_fixture`;
- legacy fixture input: `set_pointer`, `clear_pointer`, and the fixture-target
  compatibility forms of interaction commands; and
- evidence: `capture_view_tree`, `capture_screen`.

Input commands perform their own required render or frame synchronization.
Cleanup and render-generation waiting are internal lifecycle details rather
than public commands.
