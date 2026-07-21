# DwarfSpec

DwarfSpec lets you write Busted tests that interact with a running Dwarf
Fortress game through DFHack.

Your tests run inside DFHack, where they can open real UI screens, move the
pointer, send input, and wait across game frames. You still use normal Busted
features such as `describe`, `it`, hooks, and Luassert assertions. DwarfSpec
starts the run from your terminal, reports progress, cleans up test-owned UI,
and writes a machine-readable JSON result.

```lua
describe('settings screen', function()
    it('enables notifications', function()
        local screen = ds.show_fixture(
            'tests/settings/fixtures/settings.fixture.lua')
        local checkbox = ds.get(screen, 'notifications')

        ds.click(checkbox)

        assert.is_true(checkbox:getOptionValue())
    end)
end)
```

## Requirements

- Dwarf Fortress with DFHack installed and running;
- Lua 5.3 or newer;
- LuaRocks for the selected Lua installation; and
- `dfhack-run` available through `DFHACK_ROOT`, `DFHACK_RUNNER`, or `PATH`.

For live automation, use a Lua toolchain that matches DFHack's embedded Lua
version. This avoids mixing packages built for different Lua versions.

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
    fixtures/
      settings.fixture.lua
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

Use an explicitly imported fixture to create test-owned UI:

```lua
describe('search dialog', function()
    local screen

    before_each(function()
        screen = ds.show_fixture(
            'tests/search/fixtures/search.fixture.lua')
    end)

    it('accepts a query', function()
        local input = ds.get(screen, 'query')

        ds.click(input)
        ds.type('granite', screen)

        assert.equals('granite', input.text)
    end)
end)
```

A screen fixture is a Lua module that returns a `new(options)` function. The
function creates a DFHack screen; DwarfSpec instruments successful renders
automatically. `gui.ZScreen` is a convenient base:

```lua
local gui = require('gui')

---@class tests.SearchFixture: gui.ZScreen
local SearchFixture = defclass(nil, gui.ZScreen)

local M = {}

---Creates the test screen.
---@param options table|nil
---@return tests.SearchFixture
function M.new(options)
    return SearchFixture(options or {})
end

return M
```

Fixtures are automatically dismissed after each example, even when an
assertion fails. You can call `ds.dismiss(screen)` when the test specifically
needs to close a screen earlier.

## Wait for live state

Use `ds.await(description, query)` when a result depends on future game
frames. The query runs once per frame until it returns a truthy value:

```lua
local results = ds.await('search results appear', function()
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
| `ds.show_fixture(path, options)` | Create and show a test-owned screen. |
| `ds.dismiss(screen)` | Dismiss a test-owned screen early. |
| `ds.stage_overlay_fixture(path)` | Legacy compatibility for registration-oriented fixture tests. |
| `ds.mount(component, options)` | Mount a widget, overlay widget, or complete screen and return its root subject. |
| `ds.root()` | Return a subject for the implicit current mount root. |
| `ds.get(view_id)` | Select a unique propagated ID from the implicit current mount. |
| `ds.unmount()` | Cleanly remove and settle the implicit current mount. |
| `ds.resize(width, height)` | Resize the mounted host and wait for its render. |
| `subject:inspect()` | Return stable, read-only information about the selected view. |
| `subject:text()` | Return the selected view's inspected text value. |
| `subject:raw()` | Access the native object as an exceptional escape hatch. |
| `ds.set_pointer(x, y)` | Set the run's virtual pointer position. |
| `subject:move_pointer(anchor)` | Move the pointer into the selected view. |
| `subject:hover(anchor)` | Hover the selected view and preserve the subject. |
| `ds.clear_pointer()` | Restore physical pointer queries. |
| `subject:click(button)` | Click the selected view and preserve the subject. |
| `subject:input(keys)` | Send native DFHack input through the mounted screen. |
| `subject:type(text)` | Type ASCII text through the mounted screen. |
| `ds.capture_view_tree(name)` | Retain the implicit mount's structured view tree. |
| `ds.capture_screen(name, options)` | Retain a bounded screen-cell capture. |

See [Writing live tests](docs/writing-tests.md) for fixture and overlay
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
