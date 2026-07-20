# Writing live tests

DwarfSpec discovers only files matching `tests/**/*_spec.ds.lua`. This keeps
live tests separate from ordinary Busted unit specs while preserving normal
Busted `describe`, `it`, hooks, and Luassert assertions.

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
