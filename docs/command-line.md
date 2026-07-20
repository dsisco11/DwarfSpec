# Command-line reference

`dwarfspec` is the single external entry point. Invoking it without a
subcommand prints help and does not discover tests, connect to DFHack, or run
Lua code.

## Canonical identities and globs

`dwarfspec list` discovers only `tests/**/*_spec.ds.lua`. Each displayed test
identity is the case-sensitive project-relative path with `/` separators, for
example `tests/tooltip/hover_spec.ds.lua`. Identities refer to spec files, not
individual Busted examples, so listing never has to execute a test body or
hook.

Both `list <glob>` and `run <glob>` use exactly the same matcher:

- `*` matches zero or more characters within one path segment;
- `**` matches zero or more characters across path separators;
- `?` matches one character other than `/`;
- `\` escapes the next character; and
- matching is case-sensitive.

Character classes and runs of three or more stars are malformed. A malformed
glob and a valid glob with no matches both return nonzero with distinct
diagnostics. Multiple matches retain the deterministic order printed by
`list` and execute in one Busted run.

## Commands

```text
dwarfspec list [glob] [--project-root PATH]
dwarfspec run [glob] [options]
dwarfspec abort RUN_ID [--runner PATH]
dwarfspec help [command]
dwarfspec version
```

`run` supports project-root selection, Busted filters and tags, repeat count,
external timeout and polling controls, lease controls, explicit overlay
fixture definitions, result-directory selection, explicit run ids, and verbose
runner diagnostics. `dwarfspec help run` prints the complete option list.

The runner lookup order is an explicit `--runner`, `DFHACK_RUNNER`,
`DFHACK_ROOT/hack/dfhack-run`, and finally `PATH`.

## Results and exit status

The default result directory is `.test-results/dwarfspec/` beneath the
consumer project. Once the native host has produced a report, the command
writes its exact DFHack-encoded JSON payload to `<run-id>.json`. The payload
has schema `dwarfspec.run.v1` and includes the run state, Busted totals,
failure details, output position, and cleanup confirmation. The external
command does not re-encode it. `--results PATH` selects another directory;
`--no-results` disables persistence. Failures before a native report exists
do not create a result file.

Exit codes are stable:

| Code | Meaning |
|---:|---|
| 0 | Help, version, listing, or a passing run with confirmed cleanup |
| 2 | Invalid command, option, argument, or malformed glob |
| 3 | Missing dependency, invalid project, or no selected tests |
| 4 | DFHack connection or core-context failure |
| 5 | Host, report, status, or result persistence failure |
| 6 | Busted failure/error or unconfirmed cleanup |
| 7 | External wall-clock timeout |
| 8 | Aborted run |

On timeout, interruption, or a malformed status report after bootstrap, the
command attempts an explicit native abort and preserves the final abort report
without hiding the original failure.
