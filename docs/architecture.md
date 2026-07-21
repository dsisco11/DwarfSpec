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

DwarfSpec contains only reusable host modules, generic unit tests, and
product-independent live component specifications. Product components,
product-specific support helpers, and their specifications remain in their
consumer repositories.

The source tree reserves `src/dwarfspec/` for installed modules, `bin/` for the
cross-platform command, and `tests/` for DwarfSpec's own unit and live
framework coverage.

## Package and consumer boundary

Every host run receives two roots. The package root owns Busted, the scheduler,
cleanup, reporting, mount context, component adapters, render instrumentation,
and the `ds` implementation. The project root owns live specs, configuration
modules, custom commands, and ordinary test-support modules. Neither root is
inferred from the layout of the other.

The external command recursively discovers files whose basenames match
`*.ds.lua` beneath the project test root in stable path order by default.
Consumers can replace that discovery glob; the host receives the exact
selected files and enforces path safety instead of reimposing a filename
convention.

Modules in `tests/dwarfspec/` execute in private environments that read process
globals but retain their own global writes. Their commands are bound only onto
the run-scoped `ds` object, so product-specific inspection remains outside the
library.

## Component mount ownership

`ds.mount(component, options)` is the only component entry point. The
component boundary classifies a `widgets.Widget`, `overlay.OverlayWidget`, or
`gui.ZScreen` class or existing instance and normalizes mount-only options. A
run owns at most one implicit current mount. Calling `ds.mount()` while that
mount remains current is an error; the test must call `ds.unmount()` before
mounting another component.

The mount context assigns identity, owns the component root and host screen,
indexes propagated view IDs, retains weak subject ownership, captures command
context for diagnostics, and registers mount teardown in the run's LIFO
cleanup registry. `ds.get(view_id)` searches only that index. Fluent subjects
retain mount and selection identity, become stale as soon as their mount is no
longer current, and prevent normal commands from accepting unrelated raw
views or screens.

Ordinary widgets and overlay widgets render inside a DwarfSpec-owned
instrumented `gui.ZScreen`. The widget adapter lays out the component in the
owned viewport. The overlay adapter additionally supplies its logical name,
frame and painter selection, backing viewscreen, enable/update/input/disable
lifecycle, and mount-local position without registering a script.

A complete screen is shown directly instead of being nested inside another
host. DwarfSpec instruments that screen instance automatically and restores
its original behavior during cleanup. Render instrumentation remains private
to DwarfSpec and does not alter the component class.

Render instrumentation reports successful completed renders to a private
mount tracker. Mutating commands capture the current generation, perform the
operation synchronously in the live Busted coroutine, and wait across DFHack
frames for a later completed render before returning. Construction, first
render, and command failures receive bounded mount, selection, component-tree,
and screen diagnostics while preserving the original cause.

Every mount resource is registered before it can escape. Example completion,
assertion failure, command timeout, external timeout, lease expiry, explicit
abort, and explicit unmount all drain run-owned cleanup in strict LIFO order.
Cleanup is idempotent, continues after individual teardown failures, restores
pause and pointer state, settles screens, invalidates subjects, and reports
confirmation only after lifecycle probes verify that no active mount resource
remains.

## Overlay registration boundary

Overlay behavior tests mount `overlay.OverlayWidget` classes or instances into
the DwarfSpec-owned host. They do not install scripts, touch persisted overlay
configuration, or depend on DFHack registration. A separately named and
selected DwarfSpec integration spec owns the real registration boundary. Its
internal helper stages a run-unique `dwarfspec_*` script only when the exact
destination is absent, registers cleanup before discovery, disables the
discovered widgets, removes only unchanged staged contents, restores the exact
pre-run overlay configuration artifact, performs a final rescan, and verifies
that its registrations are gone.
