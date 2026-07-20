# Changelog

All notable changes to DwarfSpec will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Standalone repository baseline containing the reusable automation host,
  generic framework tests, and generic fixtures extracted from DwarfUI.
- Lua 5.3 syntax and repository formatting checks.
- A pinned local Busted unit-test command.

### Changed

- Renamed the unpublished public condition wait from `ds.wait_until(...)` to
  `ds.await(...)`; the diagnostic description remains required.
- Relaxed default live-spec discovery to recursive `*.ds.lua` basename
  matching, added project, environment, and command-line configuration, and
  removed the host's duplicate filename-suffix restriction.

## [0.1.0] - 2026-07-20

### Added

- LuaRocks package metadata, namespaced module installation, and the
  `dwarfspec` command launcher.
- Installation and release guidance for the portable pure-Lua rock.
