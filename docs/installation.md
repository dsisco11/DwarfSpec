# Installation

Install a released DwarfSpec rock with Lua 5.4 and LuaRocks:

```powershell
luarocks install dwarfspec
```

For a local release candidate, build and install the generated rock instead of
loading files from a sibling checkout:

```powershell
luarocks install .\dwarfspec-0.1.0-1.all.rock
```

The release procedure produces that portable artifact in a Linux LuaRocks
environment with `arch = 'all'`. This is deliberate: DwarfSpec contains only
Lua modules plus a Unix shell launcher and a Windows batch launcher. It does
not contain a compiled module. On Windows, add the selected rock tree's `bin`
directory and the Lua interpreter directory to `PATH`, then run:

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

The external command uses Lua 5.4 dependencies. When it invokes DFHack, the
installed host adds only pure-Lua module paths for DwarfSpec and Busted. It
does not add the external Lua 5.4 native-module path to DFHack.
