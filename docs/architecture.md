# Architecture

DwarfSpec has four explicit responsibilities:

- an external command coordinates a run through `dfhack-run`;
- an in-process host embeds Busted in DFHack's core Lua context;
- a run-scoped driver exposes live UI operations to isolated specs; and
- schedulers, cleanup registries, adapters, and reports make each run
  deterministic and reversible.

Busted remains responsible for test discovery, test structure, hooks,
assertions, and result classification. DwarfSpec does not implement a second
test framework.

## Extraction boundary

The initial history import contains only reusable host modules, generic unit
tests, generic live specifications, and generic fixtures. DwarfUI tooltip
modules, tooltip fixtures, tooltip specifications, build tools, and product
documentation remain in DwarfUI.

The source tree reserves `src/dwarfspec/` for installed modules, `bin/` for the
cross-platform command, and `tests/` for DwarfSpec's own unit and live
framework coverage.

## Package and consumer boundary

Every host run receives two roots. The package root owns Busted, the scheduler,
cleanup, reporting, and the `ds` implementation. The project root owns live
specs, configuration modules, custom commands, and fixtures.
Neither root is inferred from the layout of the other.

The external command recursively discovers files whose basenames match
`*.ds.lua` beneath the project test root in stable path order by default.
Consumers can replace that discovery glob; the host receives the exact
selected files and enforces path safety instead of reimposing a filename
convention.

Modules in `tests/dwarfspec/` execute in private environments that read process
globals but retain their own global writes. Their commands are bound only onto
the run-scoped `ds` object, so product-specific inspection remains outside the
library.

Screen fixtures remain explicit project-relative imports while compatibility
callers migrate to component mounts.

Overlay behavior tests mount `overlay.OverlayWidget` classes or instances into
the DwarfSpec-owned host. They do not install scripts, touch persisted overlay
configuration, or depend on DFHack registration. A separately named and
selected DwarfSpec integration spec owns the real registration boundary. Its
internal helper stages a run-unique `dwarfspec_*` script only when the exact
destination is absent, registers cleanup before discovery, disables the
discovered widgets, removes only unchanged staged contents, restores the exact
pre-run overlay configuration artifact, performs a final rescan, and verifies
that its registrations are gone.
