# Changelog

All notable changes to DwarfSpec will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Standalone repository baseline containing the reusable automation host,
  generic framework tests, and product-independent component coverage.
- LuaRocks package metadata, namespaced module installation, and the
  `dwarfspec` command launcher.
- Installation and release guidance for the portable pure-Lua rock.
- Unified component mounting for ordinary widgets, overlay widgets, and
  complete screens supplied as classes or existing instances.
- Fluent mount subjects for selection, interaction, inspection, text access,
  and exceptional native-object access.
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
