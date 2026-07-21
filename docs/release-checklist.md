# Release checklist

1. Set the rock version and revision in the rockspec.
2. Add the release notes to `CHANGELOG.md`.
3. Parse all repository Lua files with Lua 5.3 and Lua 5.4, then run the full
   unit suite with the development toolchain.
4. Run the VS Code `Publish` task, or `tools/Publish.ps1`. It lints a temporary
   correctly versioned copy of `dwarfspec.rockspec` and builds the binary
   release rock with LuaRocks configured as `arch = 'all'`. The archive
   contains only Lua code and the paired Unix and Windows text launchers; it
   is written to `dist/<package>-<version>.all.rock`.
5. Inspect the archive manifest and confirm it contains no native library.
6. Install the binary rock into an empty LuaRocks tree and run command and
   module smoke checks from that tree on Windows and Linux.
7. Run the live DFHack package proof with the installed command.
8. Tag the exact release commit as `v<version>`.
9. Copy `dwarfspec.rockspec` to its versioned release filename, build the
   source rock with `luarocks pack`, and verify that it resolves the new tag.
10. Upload the validated source rock to LuaRocks.
11. Install the uploaded rock into a new empty tree and repeat the smoke check.
