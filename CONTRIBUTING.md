# Contributing to DwarfSpec

Keep changes focused and preserve the distinction between local unit coverage
and tests that require a running DFHack process.

Before submitting a change:

1. Run `tools/Check-Lua.ps1` with the system-default Lua 5.4 toolchain on
   `PATH`.
2. Confirm `lua` and `luarocks config lua_version` report the same major and
   minor version, then run `tools/Run-UnitTests.ps1`.
3. Run any additional supported-version compatibility checks required by the
   release checklist.
4. Run the relevant live DFHack specifications when host behavior changes.
5. Document every Lua module and function with triple-dash LuaDoc prose.

Use four spaces for indentation, LF line endings, no tabs, no trailing
whitespace, and a final newline. Production framework modules ultimately live
under `src/dwarfspec/`; unit and generic live framework coverage live under
`tests/`.

The extracted legacy layout is temporary. Keep mechanical moves, public API
renames, and behavior changes in separate commits whenever practical so each
kind of change remains reviewable.
