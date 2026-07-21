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
    self:addviews{widgets.ToggleHotkeyLabel{
        view_id='notifications',
        frame={l=0, t=0},
        label='Notifications',
        initial_option=false,
    }}
end

describe('settings screen', function()
    it('enables notifications', function()
        ds.mount(SettingsPanel)
        ds.get('notifications'):click()
        assert.is_true(ds.get('notifications'):raw():getOptionValue())
    end)
end)
```

## Requirements

- Dwarf Fortress with DFHack installed and running;
- Lua 5.3 or newer;
- LuaRocks for the selected Lua installation; and
- `dfhack-run` available through `DFHACK_ROOT`, `DFHACK_RUNNER`, or `PATH`.

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
to `PATH`. You can point DwarfSpec at DFHack with an environment variable:

```powershell
$env:DFHACK_ROOT = 'C:\Games\Dwarf Fortress'
dwarfspec help
```

See [the installation guide](docs/installation.md) for local rocks, custom
LuaRocks trees, and development servers.

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
classes or instances through the same entry point. It owns the host,
instruments successful renders automatically, and cleans up the current mount
after each example. Reusable factories remain ordinary Lua helpers; DwarfSpec
does not require a fixture-module protocol.

```lua
local gui = require('gui')

---@class tests.SearchFixture: gui.ZScreen
local SearchFixture = defclass(nil, gui.ZScreen)

ds.mount(SearchFixture, {initial_pause=false})
```

Mounts are automatically removed after each example, even when an assertion
fails. Call `ds.unmount()` when a test specifically needs to remove one early.

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
| `ds.mount(component, options)` | Mount a widget, overlay widget, or complete screen and return its root subject. |
| `ds.root()` | Return a subject for the implicit current mount root. |
| `ds.get(view_id)` | Select a unique propagated ID from the implicit current mount. |
| `ds.unmount()` | Cleanly remove and settle the implicit current mount. |
| `ds.resize(width, height)` | Resize the mounted host and wait for its render. |
| `subject:inspect()` | Return stable, read-only information about the selected view. |
| `subject:text()` | Return the selected view's inspected text value. |
| `subject:raw()` | Access the native object as an exceptional escape hatch. |
| `subject:move_pointer(anchor)` | Move the pointer into the selected view. |
| `subject:hover(anchor)` | Hover the selected view and preserve the subject. |
| `subject:click(button)` | Click the selected view and preserve the subject. |
| `subject:input(keys)` | Send native DFHack input through the mounted screen. |
| `subject:type(text)` | Type ASCII text through the mounted screen. |
| `ds.capture_view_tree(name)` | Retain the implicit mount's structured view tree. |
| `ds.capture_screen(name, options)` | Retain a bounded screen-cell capture. |
| `ds.stage_overlay_registration(source, name)` | Stage a run-owned script only for separately selected real-registration integration coverage. |

See [Writing live tests](docs/writing-tests.md) for component and overlay
contracts.

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
        selected_text=function(ds, view)
            return ds.inspect(view).text
        end,
    },
}
```

The command is then available as `ds.selected_text(view)` in every live spec.
Keep module top-level code portable and make DFHack-only calls inside command
callbacks. See [Consumer configuration](docs/configuration.md) for discovery
overrides and extension rules.

## Results and cleanup

The terminal shows each example as it starts and finishes. A run succeeds only
when all Busted examples pass and DwarfSpec confirms cleanup.

By default, the final DFHack-generated report is written to:

```text
.test-results/dwarfspec/<run-id>.json
```

Use `--results PATH` to choose another project-relative directory or
`--no-results` to disable report files. The JSON document uses the
`dwarfspec.run.v1` schema and includes totals, failures, run state, and cleanup
status.

See the [command-line reference](docs/command-line.md) for glob syntax, runner
selection, abort behavior, and exit codes.

## More documentation

- [Installation](docs/installation.md)
- [Writing live tests](docs/writing-tests.md)
- [Configuration](docs/configuration.md)
- [Command-line reference](docs/command-line.md)
- [Contributing](CONTRIBUTING.md)

## License

DwarfSpec is available under the [MIT License](LICENSE).
