# Release checklist

1. Set the rock version and revision in the rockspec.
2. Add the release notes to `CHANGELOG.md`.
3. Run the syntax check and full unit suite with Lua 5.3 on `PATH`.
4. Run `luarocks lint`, then build the source rock with `luarocks pack`.
5. Build the binary release rock in Linux with LuaRocks configured as
   `arch = 'all'`. The archive contains only Lua code and the paired Unix and
   Windows text launchers; it must be named `<package>-<version>.all.rock`.
6. Inspect the archive manifest and confirm it contains no native library.
7. Install the binary rock into an empty LuaRocks tree and run command and
   module smoke checks from that tree on Windows and Linux.
8. Run the live DFHack package proof with the installed command.
9. Tag the exact release commit as `v<version>`.
10. Upload the validated source rock to LuaRocks.
11. Install the uploaded rock into a new empty tree and repeat the smoke check.
