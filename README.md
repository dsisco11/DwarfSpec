# DwarfSpec

DwarfSpec is an in-process Busted host for automating live DFHack user
interfaces. It lets a Busted test yield across real game frames, interact with
test-owned screens, and receive deterministic results and cleanup diagnostics.

The host resolves its own package files independently from the consumer
project. Consumer live specs default to recursively discovered `*.ds.lua`
files beneath `tests/`; the discovery glob is configurable without changing
the optional second-stage selection glob. The public `ds` object exists only
inside each isolated Busted spec environment.

Consumer-wide settings and extensions are optional. Put them in
`tests/dwarfspec/*.lua`; `config.lua` is loaded first, followed by the other
modules in stable path order. Fixtures are imported explicitly. The recommended
co-located name is `tests/**/fixtures/*.fixture.lua`, but any safe importable
project-relative Lua module can be used.

## Development

Requirements:

- Lua 5.3 and LuaRocks; and
- PowerShell 7 or Windows PowerShell 5.1.

Run the repository checks from its root:

```powershell
./tools/Check-Lua.ps1
./tools/Run-UnitTests.ps1
```

Both commands use the `lua` executable on `PATH` and reject any version other
than Lua 5.3. The unit runner installs its pinned Busted dependencies into the
ignored local `.luarocks/` tree and executes only the framework unit tests.
Live DFHack specs remain a separate verification layer.

See [CONTRIBUTING.md](CONTRIBUTING.md) for repository conventions and
[docs/architecture.md](docs/architecture.md) for the package boundary. See
[docs/configuration.md](docs/configuration.md) and
[docs/writing-tests.md](docs/writing-tests.md) for the consumer contracts.
See [docs/installation.md](docs/installation.md) for local, development-server,
and public LuaRocks installs, and [docs/release-checklist.md](docs/release-checklist.md)
for release validation.

## License

DwarfSpec is available under the [MIT License](LICENSE).
