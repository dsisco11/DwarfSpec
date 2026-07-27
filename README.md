# DwarfSpec

DwarfSpec lets you write Busted tests that interact with a running Dwarf
Fortress game through DFHack.

Your tests run inside DFHack, where they can open real UI screens, move the
pointer, send input, and wait across game frames. You still use normal Busted
features such as `describe`, `it`, hooks, and Luassert assertions. DwarfSpec
starts the run from your terminal, reports progress, cleans up test-owned UI,
and writes a machine-readable JSON result.

```lua
local widgets = require('gui.widgets')

---@class tests.SettingsPanel: gui.widgets.Panel
local SettingsPanel = defclass(nil, widgets.Panel)

---Builds the settings controls under test.
function SettingsPanel:init()
    self:addviews{
        widgets.HotkeyLabel{
            view_id='notifications',
            frame={l=0, t=0},
            label='Enable notifications',
            on_activate=self:callback('enable_notifications'),
        },
        widgets.Label{
            view_id='status',
            frame={l=0, t=2},
            text='disabled',
        },
    }
end

---Updates the visible settings state.
function SettingsPanel:enable_notifications()
    self.subviews.status:setText('enabled')
end

describe('settings screen', function()
    it('enables notifications', function()
        ds.mount(SettingsPanel)
        ds.get('notifications'):click()
        assert.equals('enabled', ds.get('status'):text())
    end)
end)
```

## Requirements

- Dwarf Fortress with DFHack installed and running;
- Lua 5.3 or newer;
- LuaRocks for the selected Lua installation; and
- access to `dfhack-run`, preferably through a project-local `.env` file whose
  `DFHACK_ROOT` points to the directory containing the runner.

The external Lua toolchain does not need to match DFHack's embedded Lua
version. DwarfSpec sends pure-Lua dependencies to the live host, which loads
them with DFHack's own interpreter and replaces native system modules with
host adapters.

## Installation

Install DwarfSpec from LuaRocks:

```powershell
luarocks install dwarfspec
dwarfspec version
```

If the command is not found, add the selected LuaRocks tree's `bin` directory
to `PATH`.

The recommended DFHack configuration is a `.env` file in the consumer project
root. Add `.env` to the project's `.gitignore`, then set `DFHACK_ROOT` to the
directory containing `dfhack-run.exe` or `dfhack-run`:

```text
DFHACK_ROOT=C:\Games\Dwarf Fortress\hack
```

DwarfSpec loads this file automatically when invoked for the project. This
keeps the machine-specific DFHack installation path out of commands and source
control. Existing process environment variables override the project file;
use `--runner` only when one invocation needs a different executable.

See [the installation guide](docs/installation.md) for local rocks, custom
LuaRocks trees, and development servers.

For local live automation from this source checkout, copy `.env.example` to
`.env`, set `DFHACK_ROOT` to the DFHack installation containing
`dfhack-run.exe`, and run:

```powershell
.\tools\Run-AutomationTests.ps1
```

With no arguments, the script runs the product live specifications under
`tests/automation/`. Pass normal `dwarfspec run` selectors after the
script name. The `.env` file is local-only and is not read by GitHub Actions.

## Add DwarfSpec to a project

By default, DwarfSpec recursively discovers files named `*.ds.lua` beneath
your project's `tests/` directory. A typical layout is:

```text
tests/
  settings/
    settings.ds.lua
    support/
      settings_data.lua
  dwarfspec/
    config.lua
```

Run commands from the project root. Use `list` to check discovery without
loading or executing the test files:

```powershell
dwarfspec list
dwarfspec run
```

You can select a subset with a project-relative glob:

```powershell
dwarfspec run 'tests/settings/**'
dwarfspec run --filter 'enables notifications'
```

Run `dwarfspec help run` for all selection, timeout, reporting, and runner
options.

## Write a live test

DwarfSpec provides a run-scoped `ds` object inside each live spec. It does not
add `ds` to the process-wide Lua globals.

Mount a component class or already-created instance to create test-owned UI:

```lua
describe('search dialog', function()
    before_each(function()
        ds.mount(SearchScreen, {initial_pause=false})
    end)

    it('accepts a query', function()
        ds.get('query'):click():type('granite')
        assert.equals('granite', ds.get('query'):text())
    end)
end)
```

DwarfSpec accepts `widgets.Widget`, `overlay.OverlayWidget`, and `gui.ZScreen`
classes or instances through the same component entry point. Component mounts
own their UI host, instrument successful renders automatically, and use a 128
by 64 DF-cell viewport by default; pass
`viewport={width=..., height=...}` to select another size. Reusable factories
remain ordinary Lua helpers.

```lua
local gui = require('gui')

---@class tests.SearchScreen: gui.ZScreen
local SearchScreen = defclass(nil, gui.ZScreen)

ds.mount(SearchScreen, {initial_pause=false})
```

Call `ds.mountNativeScreen()` to borrow the base native DF viewscreen without
creating, showing, or dismissing a DwarfSpec screen. Native widget lookup stays
rooted in that borrowed screen, while simulated player input is dispatched
through whichever viewscreen is current when the input is sent:

```lua
ds.mountNativeScreen()
local menu = ds.get('menu')
assert.is_table(menu:inspect().body)
```

All mounts or attachments are automatically cleaned after each example, even
when an assertion fails. Call `ds.unmount()` when a test specifically needs to
release one early.

## Wait for live state

Use `ds.await(description, query)` when a result depends on future game
frames. The query runs once per frame until it returns a truthy value:

```lua
local results = ds.await('search results appear', function()
    local screen = ds.root():raw()
    return #screen.results > 0 and screen.results
end)

assert.equals('granite', results[1].text)
```

The description is included in timeout diagnostics. You can override the
default limits for one wait:

```lua
ds.await('world finishes loading', function()
    return dfhack.isWorldLoaded()
end, {frame_budget=600, timeout_ms=20000})
```

Input commands perform their required render or frame synchronization
automatically. Use `ds.wait_frames(count)` only when the number of elapsed game
frames is itself part of the behavior being tested.

## The `ds` commands

| Command | Purpose |
|---|---|
| `ds.await(description, query, options)` | Poll a condition between live frames. |
| `ds.wait_frames(count, options)` | Wait for a specific number of DFHack frames. |
| `ds.getTick()` | Return the current in-year simulation tick for the loaded world. |
| `ds.getTime()` | Return DFHack's current millisecond clock value. |
| `ds.hasFocus(path)` | Return whether the current DFHack focus matches a focus path. |
| `ds.getViewPos(origin)` | Return the map tile aligned with an `EScreenOrigin`; defaults to `CENTER`. |
| `ds.setViewPos({x=..., y=..., z=...}, origin)` | Align a map tile with an `EScreenOrigin`; defaults to `CENTER`, and cleanup restores the original view. |
| `ds.mount(component, options)` | Mount a widget, overlay widget, or complete screen and return its root subject. |
| `ds.mountNativeScreen()` | Attach non-owningly to the base native DF viewscreen and return its widget-root subject. |
| `ds.root(options)` | Return the selected native, registered-overlay, or component root subject. |
| `ds.get(control_path, options)` | Select one exact source-specific path from the current mount. |
| `ds.unmount()` | Cleanly remove and settle the implicit current mount. |
| `ds.viewport(width, height)` | Change the mounted viewport in DF cells and wait for its render. |
| `ds.inspect(subject)` | Return stable, read-only information about a subject or the selected root. |
| `subject:inspect()` | Return stable, read-only information about the selected view. |
| `subject:getFocusList()` | Return a copied focus-string list for the subject's mounted screen. |
| `subject:text()` | Return the selected view's inspected text value. |
| `subject:raw()` | Access the borrowed Lua view or native DF widget as an exceptional escape hatch. |
| `ds.move_pointer(x, y, space)` | Move by zero-based UI-grid cell by default, or by exact screen pixel with `EPointerSpace.PIXELS`. |
| `ds.hover(x, y, space)` | Move to a numeric pointer coordinate and wait for the mounted screen to settle. |
| `subject:move_pointer(anchor)` | Move the pointer into the selected view. |
| `subject:hover(anchor)` | Hover the selected view and preserve the subject. |
| `ds.click(subject, button)` | Move to and click a subject with a supported physical mouse button. |
| `subject:click(button)` | Click the selected view and preserve the subject. |
| `ds.input(keys, subject)` | Send native DFHack input through the subject's mount. |
| `subject:input(keys)` | Send native DFHack input through the mounted screen. |
| `ds.type(text, subject)` | Type ASCII text through the subject's mount. |
| `subject:type(text)` | Type ASCII text through the mounted screen. |
| `ds.mouseInput(button, action)` | Send an `EMouseButton` action at the current pointer position; physical buttons default to `EInputState.CLICK`. |
| `ds.redraw(subject, options)` | Invalidate the mounted screen and wait by default; use `{wait=false}` to skip the wait. |
| `subject:redraw(options)` | Redraw the subject's mounted screen, preserve the subject, and wait by default. |
| `ds.capture_view_tree(name, options)` | Retain the selected source's structured view tree. |
| `ds.capture_screen(name, options)` | Retain a bounded screen-cell capture. |
| `ds.stage_overlay_registration(source, name)` | Stage a run-owned script only for separately selected real-registration integration coverage. |

### Pointer coordinate spaces

Use `ds.EPointerSpace.GRID` for UI-grid cells and
`ds.EPointerSpace.PIXELS` for exact screen pixels:

```lua
ds.move_pointer(12, 8) -- GRID is the backward-compatible default
ds.move_pointer(12, 8, ds.EPointerSpace.GRID)
ds.move_pointer(420, 260, ds.EPointerSpace.PIXELS)
```

`ds.hover()` accepts the same numeric coordinate-space overloads.

UI widgets, subjects, and subject anchors use UI-grid cells. Premium map mouse
interaction uses screen pixels, so use `PIXELS` when a test must target an exact
rendered map location. Map tiles are a third coordinate system: map-view
positions such as those returned by `ds.getViewPos()` are not pointer
coordinates.

DwarfSpec reads the effective renderer geometry on every move, so conversion
tracks the current runtime UI scale. Configured scaling preferences are not
used as a substitute for that live geometry. DwarfSpec keeps the UI-grid and
pixel positions paired for input and automatically restores both during
cleanup.

See [Writing live tests](docs/writing-tests.md) for owned-component, borrowed
native-screen, and external-overlay contracts.

### Map-view screen origins

`ds.getViewPos()` and `ds.setViewPos()` default to `CENTER`. Pass a
`ds.EScreenOrigin` value to address another point in the visible map viewport:

```lua
local center = ds.getViewPos()
ds.setViewPos({x=120, y=85, z=14})
ds.setViewPos({x=0, y=0, z=14}, ds.EScreenOrigin.TOP_LEFT)
```

The enum exposes `TOP_LEFT`, `TOP`, `TOP_RIGHT`, `LEFT`, `CENTER`, `RIGHT`,
`BOTTOM_LEFT`, `BOTTOM`, and `BOTTOM_RIGHT`. Center offsets match DFHack's
viewport convention: `floor(width/2)` and `floor(height/2)`.

## Project configuration and custom commands

Configuration is optional. Put project-wide settings in
`tests/dwarfspec/config.lua`:

```lua
return {
    settings={
        discovery={test_glob='*.ds.lua'},
        wait={frame_budget=300, timeout_ms=10000},
    },
}
```

Lua modules directly beneath `tests/dwarfspec/` can also add project-specific
commands to `ds`:

```lua
return {
    commands={
        selected_text=function(_, subject)
            return subject:text()
        end,
    },
}
```

The command is then available as `ds.selected_text(ds.get('status'))` in every
live spec.
Keep module top-level code portable and make DFHack-only calls inside command
callbacks. See [Consumer configuration](docs/configuration.md) for discovery
overrides and extension rules.

## Results and cleanup

The terminal shows each example as it starts and finishes. A run succeeds only
when all Busted examples pass and DwarfSpec confirms cleanup.

Concurrent projects can submit to the same DFHack instance. Runs wait in one
FIFO and execute one at a time. `--queue-timeout` controls the wait for
activation and defaults to `unlimited`; the existing `--timeout` begins only
after activation. Cursor-based status polling renews the applicable queue or
execution lease and formats the structured service events shown in the
terminal.

Use `dwarfspec status` to inspect the shared executor, queue, and quarantine
without changing service state. If cleanup was not confirmed, new runs are
rejected before admission with the exact blocking identity. After confirming
that no live run is active, use the command reported by status:

```text
dwarfspec recover-executor RUN_ID --generation N
```

Recovery remains gated by DFHack-side clean-state verification and has no
force mode. Healthy concurrent projects continue to wait in the shared FIFO.

Use `dwarfspec history` to list every run retained by the current DFHack service
instance, `dwarfspec show RUN_ID` to examine its immutable snapshot and
structured events, and `dwarfspec logs RUN_ID` to print its captured output.
These reads cover all concurrent projects without changing leases or scheduler
state. The in-memory history is cleared when DFHack exits.

The in-game runner UI is a separate design and implementation effort. It will
consume the same presentation-neutral service directly inside DFHack, but no
UI source or UI completion criterion is part of the test-runner service
release.

By default, the latest invocation result is written to:

```text
tests/.test-results/dwarfspec/results.json
```

Each invocation safely replaces that one project-local file; normal runs do
not accumulate run-ID-named files. The read-only session history above is
independent of result persistence. Use `--results PATH` to choose an exact
file, with relative paths resolved beneath the project root, or `--no-results`
to disable file writes. The `dwarfspec.result.v2` document includes the whole
invocation state, classified errors, native host report, structured events,
and cleanup status.

See the [command-line reference](docs/command-line.md) for glob syntax, runner
selection, abort behavior, and exit codes.

## More documentation

- [Installation](docs/installation.md)
- [Writing live tests](docs/writing-tests.md)
- [Configuration](docs/configuration.md)
- [Command-line reference](docs/command-line.md)
- [Architecture](docs/architecture.md)
- [Contributing](CONTRIBUTING.md)

## License

DwarfSpec is available under the [MIT License](LICENSE).
