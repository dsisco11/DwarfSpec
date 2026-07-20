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
Screen fixture modules return a table with `new(options)` and produce a shown
DFHack screen instrumented with a numeric `render_generation` field.

## Condition waits

`ds.await(description, query, options)` polls a read-only query between live
DFHack frames until it returns a truthy value. The required description names
the operation in progress and is included in timeout diagnostics.

```lua
local renderer = ds.await('tooltip becomes visible', function()
    local state = ds.diagnostic('tooltip')
    return state.screen.renderer.visible and state.screen.renderer
end)
```

The truthy query result is returned to the test. Optional `frame_budget` and
`timeout_ms` values override the project-wide wait settings for one operation.
Use `ds.wait_frames(count)` only when the number of raw DFHack frames is itself
part of the contract.

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
final rescan through automatic cleanup.
