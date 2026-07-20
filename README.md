# DwarfSpec

DwarfSpec is an in-process Busted host for automating live DFHack user
interfaces. It lets a Busted test yield across real game frames, interact with
test-owned screens, and receive deterministic results and cleanup diagnostics.

This repository currently contains the mechanically extracted reusable host
from DwarfUI. The extraction deliberately retains the original internal paths
and public names so its behavior and history can be reviewed before the
DwarfSpec namespace and LuaRocks packaging changes are applied.

## Development

Requirements:

- Lua 5.3 for the compatibility syntax gate;
- Lua 5.4 and LuaRocks for the current local unit-test toolchain; and
- PowerShell 7 or Windows PowerShell 5.1.

Run the repository checks from its root:

```powershell
./Tools/Check-Lua.ps1 -LuaCommand lua5.3
./Tools/Run-Unittests.ps1
```

`LUA53` can provide the Lua 5.3 executable when `-LuaCommand` is omitted. The
unit runner installs its pinned Busted dependencies into the ignored local
`.luarocks/` tree and executes only the framework unit tests. Live DFHack specs
remain a separate verification layer.

See [CONTRIBUTING.md](CONTRIBUTING.md) for repository conventions and
[docs/architecture.md](docs/architecture.md) for the extraction boundary.

## License

DwarfSpec is available under the [MIT License](LICENSE).
