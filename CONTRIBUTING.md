# Contributing to DwarfSpec

Keep changes focused and preserve the distinction between local unit coverage
and tests that require a running DFHack process.

Before submitting a change:

1. Run `tools/Check-Lua.ps1` with the system-default Lua 5.4 toolchain on
   `PATH`.
2. Confirm `lua` and `luarocks config lua_version` report the same major and
   minor version, then run `tools/Run-UnitTests.ps1`.
3. Compile the same repository Lua files with Lua 5.3. DFHack's embedded Lua
   5.3 is an acceptable compatibility compiler; the external Lua and LuaRocks
   toolchain does not need to match it.
4. Copy `.env.example` to `.env`, set `DFHACK_ROOT` to the local installation,
   then run `tools/Run-AutomationTests.ps1` with relevant selectors when host
   behavior changes.
5. Document every Lua module and function with triple-dash LuaDoc prose.

Standalone Busted unit specs live under `tests/unit/`. Live DFHack specs live
under `tests/automation/` and are not executed by `tools/Run-UnitTests.ps1` or
GitHub Actions. This repository's automation script selects that directory;

Use four spaces for indentation, LF line endings, no tabs, no trailing
whitespace, and a final newline. Production framework modules ultimately live
under `src/dwarfspec/`; unit and generic live framework coverage live under
`tests/`.

The extracted legacy layout is temporary. Keep mechanical moves, public API
renames, and behavior changes in separate commits whenever practical so each
kind of change remains reviewable.
