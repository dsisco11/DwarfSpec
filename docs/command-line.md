# Command-line reference

`dwarfspec` is the single external entry point. Invoking it without a
subcommand prints help and does not discover tests, connect to DFHack, or run
Lua code.

## Canonical identities and globs

`dwarfspec list` recursively discovers basenames matching `*.ds.lua` beneath
`tests/` by default. Each displayed test identity is the case-sensitive
project-relative path with `/` separators, for example
`tests/tooltip/hover.ds.lua`. Identities refer to spec files, not individual
Busted examples, so listing never has to execute a test body or hook.

`settings.discovery.test_glob` in `tests/dwarfspec/config.lua` sets the project
discovery glob. `DWARFSPEC_TEST_GLOB` overrides the project setting, and
`--test-glob GLOB` overrides both for one `list` or `run` command. Discovery
globs use the same syntax as selection globs. A pattern without a path
separator is matched against each recursively visited basename; a pattern with
a separator is matched against the complete canonical identity.

The optional positional glob is a second-stage selection over the discovered
identities. Both `list <glob>` and `run <glob>` use exactly the same matcher:

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
dwarfspec list [glob] [--project-root PATH] [--test-glob GLOB]
dwarfspec run [glob] [options]
dwarfspec abort RUN_ID [--project-root PATH] [--runner PATH]
dwarfspec help [command]
dwarfspec version
```

`run` supports project-root and discovery-glob configuration, Busted filters
and tags, repeat count, separate queue and execution timeouts, polling and
lease controls, exact result-file selection, explicit run ids, and verbose
runner diagnostics. `dwarfspec help run` prints the complete option list.

Multiple projects can submit runs concurrently to one DFHack instance. They
wait in deterministic FIFO order while DwarfSpec keeps one live executor.
`--queue-timeout SECONDS` limits the wait for activation; its default and the
explicit value `unlimited` allow an unbounded wait. `--timeout SECONDS` starts
only after the service reports activation, so time in the queue never consumes
the execution budget. Every successful status poll renews whichever external
queue or execution lease applies.

The recommended runner configuration is `DFHACK_ROOT` in
`<project-root>/.env`; its value is the directory that directly contains
`dfhack-run.exe` or `dfhack-run`. DwarfSpec loads the project file
automatically. Process-environment values override `.env`, an explicit
`--runner` overrides both, and `PATH` is the final fallback. `DFHACK_RUNNER`
can identify the complete executable path instead of its containing directory.

## Live component commands

Every supported component category uses `ds.mount(component, options)` inside
the live Busted coroutine. `ds.get(control_path)` walks the one implicit current
mount through direct child IDs and returns a fluent subject; `ds.unmount()`
removes that mount early when a test needs explicit teardown. Normal interaction
commands do not take a fixture root, screen, or raw view.

`ds.mount` supports ordinary widgets, overlay widgets, and complete screens.
`ds.stage_overlay_registration` is reserved for distinctly named and
explicitly selected tests of real DFHack overlay discovery and persisted
configuration. See [Writing live tests](writing-tests.md) for the complete
component API.

## Results and exit status

The default result file is
`tests/.test-results/dwarfspec/results.json` beneath the consumer project.
Admission writes a `queued` invocation, activation replaces it with current
execution data, and completion replaces it with the terminal result. Two
sequential invocations therefore leave one file containing only the latest
invocation.

The document uses `dwarfspec.result.v2` and includes selection, classified
state, timestamps, the native host report when execution started, the complete
structured event journal, and cleanup confirmation. Dependency, connection,
registration, timeout, interruption, transport, and host failures are written
even when no native report is available.

`--results PATH` names an exact file. Relative paths resolve beneath the
project root; absolute paths remain explicit. `--no-results` validates the
complete terminal result without writing a file. A terminal service generation
is acknowledged only after its file replacement succeeds, or after successful
no-results validation.

Exit codes are stable:

| Code | Meaning |
|---:|---|
| 0 | Help, version, listing, or a passing run with confirmed cleanup |
| 2 | Invalid command, option, argument, or malformed glob |
| 3 | Missing dependency, invalid project, or no selected tests |
| 4 | DFHack connection or core-context failure |
| 5 | Host, report, status, or result persistence failure |
| 6 | Busted failure/error or unconfirmed cleanup |
| 7 | Execution timeout or the distinct queue-timeout classification |
| 8 | Active abort or the distinct pre-activation cancellation classification |

On timeout, interruption, or malformed transport after bootstrap, the command
asks the service to recover from authoritative current state. A queued run is
cancelled without native cleanup; an active run is aborted with cleanup. If
recovery also fails, the original runner failure remains primary.
