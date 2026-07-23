# Changelog

All notable changes to DwarfSpec will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Fixed

- Install one portable command script and let LuaRocks generate the appropriate
  platform launcher instead of publishing overlapping command entries.
- Reject executor quarantine before project registration or run admission and
  report the blocking run, generation, reason, and recovery command.
