# Installation

Install a released DwarfSpec rock with Lua 5.3 or newer and LuaRocks:

```powershell
luarocks install dwarfspec
```

For a local release candidate, build and install the generated rock instead of
loading files from a sibling checkout:

```powershell
luarocks install .\dist\dwarfspec-0.1.1-1.all.rock
```

The VS Code `Publish` task, or `tools/Publish.ps1`, produces that portable
artifact with LuaRocks configured as `arch = 'all'`. This is deliberate:
DwarfSpec contains only Lua modules plus a portable Lua command script. It does
not contain a compiled module. LuaRocks generates the platform-specific command
launcher when it installs the rock. On Windows, add the selected rock tree's
`bin` directory and the Lua interpreter directory to `PATH`, then run:

```powershell
dwarfspec help
```

For development against a local rock server, place the generated `.rock` and
`.rockspec` files in a directory and add it as a server for that invocation:

```powershell
luarocks install dwarfspec --server="file:///D:/rocks"
```

The public LuaRocks workflow is identical to the released install command.
Use `dwarfspec help` after installation to verify that the command resolves
from the selected rock tree.

## Configure DFHack

Create an ignored `.env` file in the consumer project root and set the absolute
directory that directly contains `dfhack-run.exe` or `dfhack-run`:

```text
DFHACK_ROOT=D:\Games\Dwarf Fortress\hack
```

`dwarfspec run` loads this configuration automatically. A process environment
variable overrides the project file, and `--runner PATH` overrides both. See
[consumer configuration](configuration.md#dfhack-runner) for the complete
lookup contract.

## Local live automation

Live DFHack specifications are intentionally local-only. From a source
checkout, copy `.env.example` to `.env` and configure the absolute installation
path:

```text
DFHACK_ROOT=D:\Games\Dwarf Fortress\hack
```

Run the relevant live specifications through the project script:

```powershell
.\tools\Run-AutomationTests.ps1
```

Pass normal `dwarfspec run` selectors after the script name. With no selectors,
it runs the product live specifications under `tests/automation/`. The `.env`
file is ignored by Git and is not used by GitHub Actions.

The external command uses its installation's Lua version, which does not need
to match DFHack's embedded Lua version. The host replaces the native `system`
and `lfs` modules with DFHack-backed adapters before Busted is loaded, so
native libraries are never loaded into the game process. DwarfSpec does not
translate dependency paths between different Lua versions within one run.
