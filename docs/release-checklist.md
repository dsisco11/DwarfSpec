# Release checklist

1. Set the rock version and revision in the rockspec.
2. Add the release notes to `CHANGELOG.md`.
3. Parse all repository Lua files with Lua 5.3 and Lua 5.4, then run the full
   unit suite with the development toolchain.
4. Run the VS Code `Publish` task, or `tools/Publish.ps1`. It validates that
   the rockspec filename matches its declared version, lints it, and builds
   the binary release rock with LuaRocks configured as `arch = 'all'`. The
   archive contains only Lua code and the paired Unix and Windows text
   launchers; it is written to `dist/<package>-<version>.all.rock`.
5. Inspect the archive manifest and confirm it contains no native library.
6. Install the binary rock into an empty LuaRocks tree and run command and
   module smoke checks from that tree on Windows and Linux.
7. Run the live DFHack package proof with the installed command.
8. Configure the `luarocks` GitHub environment with a `LUAROCKS_API_KEY`
   secret.
9. Tag the exact release commit as `v<version>` and publish its GitHub release.
   The `LuaRocks` workflow repeats the offline checks, verifies that the tag
   matches the versioned rockspec, builds the source rock, and uploads it to
   LuaRocks.org. GitHub Actions does not run the live DFHack package proof.
10. Install the uploaded rock into a new empty tree and repeat the smoke check.
