# Release checklist

1. Set the rock version and revision in the rockspec.
2. Add the release notes to `CHANGELOG.md`.
3. Run the Lua 5.3 syntax check and the full unit suite.
4. Run `luarocks lint`, then build source and binary rocks with `luarocks pack`.
5. Install the binary rock into an empty LuaRocks tree and run command and
   module smoke checks from that tree.
6. Run the live DFHack package proof with the installed command.
7. Tag the exact release commit as `v<version>`.
8. Upload the validated source rock to LuaRocks.
9. Install the uploaded rock into a new empty tree and repeat the smoke check.
