# Changelog

All notable changes to DwarfSpec will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Automatic example and file-suite guards warn when a test leaves a different
  base-game viewscreen or DFHack focus than it inherited. Comparisons occur
  after project teardown and DwarfSpec cleanup, exclude explicitly mounted
  components, retain detached diagnostics and stable warning lines, and do not
  change test results or exit status.
- `ds.mountNativeScreen()` explicitly creates a non-owning native-screen mount;
  `ds.mount(component, options)` remains component-only.
- `ds.redraw(subject, options)` and `Subject:redraw(options)` invalidate the
  mounted screen and wait for a completed render by default.
- `Subject:getFocusList()` returns a defensive copy of the mounted screen's
  DFHack focus strings.
- `ds.getTick()` returns the current in-year simulation tick, while
  `ds.getTime()` returns DFHack's millisecond clock.
- `ds.hasFocus(path)` reports whether the current DFHack focus matches a focus
  path without requiring a mount.
- `ds.EScreenOrigin` lets `ds.getViewPos(origin)` and
  `ds.setViewPos(position, origin)` address the top, center, bottom, left,
  right, and corner anchors of the visible map viewport. Omitting the origin
  selects `CENTER`, and cleanup restores the exact original raw view.
- `ds.EPointerSpace` and the optional `ds.move_pointer(x, y, space)` and
  `ds.hover(x, y, space)` overloads support exact screen-pixel positioning
  while preserving existing UI-grid calls.
- Native-screen `ds.get()` accepts complete paths rooted at
  `df.global.game.main_interface`. It traverses exact declared DF data fields,
  switches once to exact native-widget traversal, and retains the structural
  and widget path for subject reacquisition.
- Native lookup remains compatible with direct `viewscreen.widgets` paths.
  Equal results from both automatic roots are deduplicated, different
  identities fail explicitly as ambiguous, and `ds.root()` remains the exact
  borrowed viewscreen widget root.
- Native-screen subject commands can use `native_root` as an advanced
  single-root bypass for genuine ambiguity or unsupported DF structures while
  retaining the borrowed base viewscreen as their subject and redraw context.
- Native-screen mounts can select enabled registered overlays through
  `ds.ESubjectSource`, without taking ownership of the overlay.
- Live failure output supports `msbuild`, `gcc`, and `eslint` problem formats
  through `settings.error_format`.

### Changed

- Native subject lookup stays rooted in the borrowed base viewscreen, while
  keyboard, text, click, physical-button, and wheel input resolves the current
  top viewscreen immediately before each dispatch.
- Top-screen transitions no longer stale a native mount or retained subjects
  by themselves. Widget replacement, structural-root invalidation, and source
  removal or replacement remain explicit stale-subject failures.

### Fixed

- Expose normalized `scroll_position` and `visible_row_count` when inspecting
  DFHack Lua lists and native `widget_radio_rows` and `widget_table` controls,
  as well as direct native `widget_scroll_rows` controls.
- Keep DwarfSpec's UI-grid and screen-pixel pointer positions synchronized for
  moves and native mouse input, and restore both representations during
  cleanup.

## [0.2.0] - 2026-07-24

### Added

- Deterministic 128 by 64 DF-cell viewports for mounted components, explicit
  mount-time viewport overrides, and the runtime `ds.viewport(width, height)`
  command. The former `ds.resize(...)` command was removed.

- Standalone repository baseline containing the reusable automation host,
  generic framework tests, and product-independent component coverage.
- LuaRocks package metadata, namespaced module installation, and the
  `dwarfspec` command launcher.
- Installation and release guidance for the portable pure-Lua rock.
- Unified component mounting for ordinary widgets, overlay widgets, and
  complete screens supplied as classes or existing instances.
- Fluent mount subjects for selection, interaction, inspection, text access,
  and exceptional native-object access.
- Strict mounted-component-relative control paths for `ds.get(control_path)`.
  Selection walks direct `subviews` children and does not search propagated
  descendant IDs.
- A separately selected, reversible real overlay-registration integration
  helper.
- The public `ds.await(...)` condition wait with a required diagnostic
  description.
- Recursive `*.ds.lua` discovery with project, environment, and command-line
  configuration.
- DwarfSpec-owned host screens, render instrumentation, synchronization,
  diagnostics, current-mount state, and cleanup.
- Lua 5.3 compatibility and Lua 5.4 repository formatting checks.
- A pinned local Busted unit-test command.
- Automatic, non-executing project `.env` loading for `DFHACK_ROOT` and
  `DFHACK_RUNNER`, shared by `run` and `abort`.
- A process-wide multi-project FIFO test service with structured events,
  stable latest-result persistence, cleanup-gated execution, and immutable
  state and failure identifiers.
- Read-only `dwarfspec status` inspection and exact
  `dwarfspec recover-executor` recovery guarded by authoritative DFHack
  clean-state verification.
- Read-only `dwarfspec history`, `dwarfspec show RUN_ID`, and
  `dwarfspec logs RUN_ID` access to cross-project run history, structured
  events, and captured output retained by the current DFHack service instance.
- Explicit pointer-position mouse input through immutable `EMouseButton` and
  `EInputState` identifiers, including persistent button-down and button-up
  transitions and wheel input.

### Changed

- Require version 2 runner transport and result contracts. Legacy
  `dwarfspec.run.v1` reports and formatted progress protocol lines are no
  longer parsed or emitted.

### Fixed

- Install one portable command script and let LuaRocks generate the appropriate
  platform launcher instead of publishing overlapping command entries.
- Reject executor quarantine before project registration or run admission and
  report the blocking run, generation, reason, and recovery command.
- Preserve the active Lua interpreter in isolated LuaRocks publish
  configuration and recover same-version local installs after packaged files
  are renamed.
