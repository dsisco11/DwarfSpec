# Consumer configuration

## DFHack runner

Create an ignored `.env` file in the consumer project root:

```text
DFHACK_ROOT=G:\Steam\steamapps\common\Dwarf Fortress\hack
```

`DFHACK_ROOT` must be the directory that directly contains `dfhack-run.exe` or
`dfhack-run`. `dwarfspec run` and `dwarfspec abort` load the file as read-only
configuration. They do not execute it or modify the process environment.

Use `DFHACK_RUNNER` instead when the complete executable path is preferable:

```text
DFHACK_RUNNER=G:\Steam\steamapps\common\Dwarf Fortress\hack\dfhack-run.exe
```

Values already present in the process environment override `.env`. An explicit
`--runner PATH` overrides both. The file supports blank lines, comment lines,
optional `export`, quoted values, and unquoted values with trailing comments.
It does not perform shell expansion. Use `--project-root PATH` when invoking a
project from another directory.

## Test discovery

The default discovery glob is `*.ds.lua`, matched against every filename found
recursively beneath `tests/`. A glob containing a path separator instead
matches the complete canonical identity, such as `tests/live/**/*.lua`.

Set a project-wide glob in `tests/dwarfspec/config.lua`:

```lua
return {
    settings={
        discovery={test_glob='tests/live/**/*_spec.lua'},
    },
}
```

The configuration module is loaded once by the external command for discovery
and again inside DFHack for live extensions. Keep its top-level code portable
and defer DFHack-only calls to command callbacks.

`DWARFSPEC_TEST_GLOB` replaces the project setting for subsequent commands,
and `--test-glob GLOB` overrides both for one `list` or `run` command.

Discovery determines the canonical file identities available to the command.
The optional positional glob on `list` and `run` then selects from those
identities. Both operations use the documented DwarfSpec glob syntax, and the
in-process host runs the exact safe paths selected by the external command.

## In-process settings and extensions

Consumer configuration is optional. DwarfSpec loads Lua files directly under
`tests/dwarfspec/` in deterministic order: `config.lua` first, then every other
`*.lua` file alphabetically.

`config.lua` may return discovery and global wait defaults:

```lua
return {
    settings={
        discovery={test_glob='*.ds.lua'},
        wait={frame_budget=300, timeout_ms=10000},
    },
}
```

Both values are optional positive integers. Other modules cannot define
settings.

Any module in this directory may declare custom commands:

```lua
return {
    commands={
        selected_text=function(_, subject)
            return subject:text()
        end,
        tooltip_state=function(ds, service)
            return service:get_diagnostics()
        end,
    },
}
```

Commands become `ds.selected_text(...)` and `ds.tooltip_state(...)`. The first
callback argument is always the isolated run-scoped `ds` object. Names must be
Lua identifiers, duplicate names are rejected, and commands cannot replace
built-in `ds` methods.

Modules execute in isolated environments. They can read normal Lua and DFHack
globals, but assigning a global does not modify the process-wide `_G` table.
