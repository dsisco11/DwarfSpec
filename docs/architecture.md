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
cross-platform command, and `Tests/` for DwarfSpec's own unit and live
framework coverage. The preserved files retain their original paths until the
separately reviewable namespace and package-boundary migrations.
