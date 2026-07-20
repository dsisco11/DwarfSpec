# Contributing to DwarfSpec

Keep changes focused and preserve the distinction between local unit coverage
and tests that require a running DFHack process.

Before submitting a change:

1. Run `tools/Check-Lua.ps1` with Lua 5.3 on `PATH`.
2. Run `tools/Run-UnitTests.ps1` with Lua 5.3 and LuaRocks on `PATH`.
3. Run the relevant live DFHack specifications when host behavior changes.
4. Document every Lua module and function with triple-dash LuaDoc prose.

Use four spaces for indentation, LF line endings, no tabs, no trailing
whitespace, and a final newline. Production framework modules ultimately live
under `src/dwarfspec/`; unit and generic live framework coverage live under
`tests/`.

The extracted legacy layout is temporary. Keep mechanical moves, public API
renames, and behavior changes in separate commits whenever practical so each
kind of change remains reviewable.
