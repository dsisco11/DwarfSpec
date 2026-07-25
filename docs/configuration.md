# Consumer configuration

## DFHack runner

The recommended configuration is a `.env` file in the consumer project root.
It keeps the machine-specific DFHack installation path with the project, so
normal `dwarfspec` commands do not need wrappers or repeated runner arguments.

Add the file to the consumer project's `.gitignore`:

```gitignore
.env
```

Then create `.env` and set `DFHACK_ROOT`:

```text
DFHACK_ROOT=G:\Steam\steamapps\common\Dwarf Fortress\hack
```

`DFHACK_ROOT` must be the directory that directly contains `dfhack-run.exe` or
`dfhack-run`. DwarfSpec loads `<project-root>/.env` as read-only configuration.
It does not execute the file or copy its values into the process environment.

If necessary, `.env` can specify the complete executable path instead:

```text
DFHACK_RUNNER=G:\Steam\steamapps\common\Dwarf Fortress\hack\dfhack-run.exe
```

Values already present in the process environment override `.env`; this is
useful for CI or temporary shell-level configuration. An explicit
`--runner PATH` overrides both and is intended for one-off invocations. `PATH`
is the final fallback when none of those settings identifies a runner.

The `.env` file supports blank lines, comment lines, optional `export`, quoted
values, and unquoted values with trailing comments. It does not perform shell
expansion. Run DwarfSpec from the consumer project root, or use
`--project-root PATH` when invoking a project from another directory.

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

## Diagnostic output

Live test failures and errors from `dwarfspec run` can use a standard
single-line format for editor problem matchers. Select the format in
`tests/dwarfspec/config.lua`:

```lua
return {
    settings={
        error_format='msbuild',
    },
}
```

`error_format` defaults to `msbuild` when omitted. The supported values,
output shapes, and corresponding VS Code problem matchers are:

| Value | Output shape | VS Code problem matcher |
|---|---|---|
| `msbuild` | `D:\project\tests\example.ds.lua(12,4): error DS1001: suite example: expected true` | `$mscompile` |
| `gcc` | `D:/project/tests/example.ds.lua:12:4: error: suite example: expected true` | `$gcc` |
| `eslint` | `tests/example.ds.lua: line 12, col 4, Error - suite example: expected true (dwarfspec)` | `$eslint-compact` |

The `gcc` selection is compatible with both GCC and Clang diagnostic syntax.
Unlike `$mscompile` and `$eslint-compact`, `$gcc` is supplied by the Microsoft
C/C++ extension rather than core VS Code. The extension's
[Clang task example](https://code.visualstudio.com/docs/cpp/config-clang-mac)
also uses `$gcc`.

MSBuild and GCC/Clang diagnostics contain absolute source paths. ESLint Compact
diagnostics contain canonical project-relative paths because
`$eslint-compact` resolves them relative to the opened workspace folder. The
[VS Code task documentation](https://code.visualstudio.com/docs/debugtest/tasks)
describes task configuration, and its
[problem-matcher section](https://code.visualstudio.com/docs/debugtest/tasks#_processing-task-output-with-problem-matchers)
documents the built-in matcher names and their path assumptions.

For example, a one-shot task using the default format includes:

```json
{
    "label": "DwarfSpec",
    "type": "process",
    "command": "dwarfspec",
    "args": ["run"],
    "options": {
        "cwd": "${workspaceFolder}"
    },
    "problemMatcher": "$mscompile"
}
```

Do not add `isBackground` or background matcher state. `dwarfspec run` exits
after one run, so the ordinary task matcher lifecycle applies. When the task
is run again, VS Code clears the Problems contributed by its previous
invocation. DwarfSpec only prints diagnostics; it does not manage Problems
retention, grouping, or collapsing.

If a failure has no trustworthy source and line, DwarfSpec does not invent
coordinates. It prints the existing human-readable form instead:

```text
FAILURE suite example: expected true
```

The one-line diagnostic is a display projection. The complete original
message and trace remain in the persisted structured result and retained run
inspection. `dwarfspec logs RUN_ID` separately returns the captured
human-readable output lines for that run.

## In-process settings and extensions

Consumer configuration is optional. DwarfSpec loads Lua files directly under
`tests/dwarfspec/` in deterministic order: `config.lua` first, then every other
`*.lua` file alphabetically.

`config.lua` may return discovery, diagnostic-output, and global wait defaults:

```lua
return {
    settings={
        discovery={test_glob='*.ds.lua'},
        error_format='msbuild',
        wait={frame_budget=300, timeout_ms=10000},
    },
}
```

The wait values are optional positive integers. `error_format` is one of the
three values documented above. Other modules cannot define settings.

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
