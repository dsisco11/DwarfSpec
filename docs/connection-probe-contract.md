# DwarfSpec connection probe contract

## Purpose

The connection probe determines whether the resolved `dfhack-run` process can
execute the minimum DFHack core Lua API required by DwarfSpec. It runs after
project discovery and test selection but before bootstrap, admission, or test
execution.

The probe reports observed facts. The controller owns parsing, compatibility
decisions, failure classification, and user-facing diagnostics.

## Compatibility invariants

- The controller and probe protocol remains version 2.
- Every unsuccessful probe is a `RunnerFailureKind.CONNECTION` failure, maps to
  the `connection_error` invocation result state, and exits with code 4.
- A diagnostic improvement must not change project-root resolution, test
  discovery, selector glob semantics, runner lookup, registration, bootstrap,
  admission, scheduler behavior, or cleanup behavior.
- A selected spec identity is not part of a connection diagnostic unless the
  invoked subprocess independently emitted it.
- Protocol mismatches, non-core contexts, and missing required capabilities
  remain fatal. More precise reporting must not make health validation more
  permissive.
- The probe has no DwarfSpec module, project module, JSON, configuration, host
  service, or third-party dependency.
- The distributed controller and probe must come from the same DwarfSpec
  package. Shipping this contract requires a patch-version package release so
  the two artifacts are updated together.

## Probe response grammar

The probe emits exactly one response line. Unrelated output from DFHack may
appear before or after it.

```text
DWARFSPEC_PROBE protocol=2 core=true timeout=function [dfhack=<version>]
```

A candidate response line begins with the exact ASCII marker
`DWARFSPEC_PROBE`, followed by the end of the line or one ASCII space. A bare
marker is therefore a malformed candidate with missing required fields. A
marker embedded later in a line is ordinary subprocess output.

After the marker, the response consists of one or more fields separated by one
or more ASCII spaces. Each field has the form `name=value`:

- `name` matches `[a-z][a-z0-9_]*`;
- `value` matches `[A-Za-z0-9._+-]+`;
- field names are unique;
- `protocol`, `core`, and `timeout` occur exactly once;
- `protocol` is a positive base-10 integer without a sign;
- `core` is `true`, `false`, or `unavailable`;
- `timeout` is one of the Lua `type()` names `nil`, `boolean`, `number`,
  `string`, `function`, `userdata`, `thread`, or `table`, or the value
  `unavailable`.

The optional `dfhack` field contains `dfhack.VERSION` only when its string form
matches the value grammar. The probe omits it otherwise. Its presence and value
are diagnostic only and never affect health.

Unknown well-formed fields are permitted and ignored by controllers that do not
recognize them. This permits additive diagnostics without weakening required
field validation. A duplicate field, including an unknown field, is malformed
because its meaning would be ambiguous.

The probe observes incomplete contexts without indexing an unavailable value:

- when the global `dfhack` value is not a table, it reports
  `core=unavailable timeout=unavailable`;
- when `dfhack.is_core_context` is absent, `core=unavailable`;
- otherwise `core` is the string form of the boolean value, with any value
  other than `true` or `false` normalized to `unavailable`;
- when `dfhack.timeout` is absent because no DFHack table is available,
  `timeout=unavailable`;
- otherwise `timeout` is the result of Lua `type(dfhack.timeout)`, including
  `nil` when the field is absent from an available table.

A response is healthy only when it contains `protocol=2`, `core=true`, and
`timeout=function`.

## Controller classification order

The controller classifies a probe result in this order so one subprocess result
has one deterministic primary cause:

1. Invocation exception: invoking the resolved runner did not return a result.
2. Nonzero exit: the subprocess returned an exit code other than zero. Marker
   parsing is not attempted because process failure is primary.
3. Missing marker: a zero-exit result contains no candidate probe response.
4. Multiple markers: a zero-exit result contains more than one candidate.
5. Malformed response: the sole candidate violates the response grammar.
6. Protocol mismatch: the parsed protocol differs from 2.
7. Core-context failure: `core` is not `true`.
8. Timeout-capability failure: `timeout` is not `function`.
9. Healthy response: every required field has its accepted value.

The controller searches the complete output instead of requiring the probe to
be the final line. Unrelated output does not invalidate one otherwise healthy
response.

## Diagnostic catalog

Messages use these stable forms. Angle-bracketed terms are substituted with
observed, cleaned, and bounded values.

| Condition | Diagnostic |
| --- | --- |
| Invocation exception | `Could not invoke DFHack runner "<runner>": <error>` |
| Nonzero exit | `DFHack connection probe through "<runner>" exited with code <code>. Output: <excerpt>` |
| Missing marker | `DFHack responded through "<runner>", but emitted no DwarfSpec probe report. Output: <excerpt>` |
| Multiple markers | `DFHack emitted <count> DwarfSpec probe reports; expected exactly one. Output: <excerpt>` |
| Malformed response | `DFHack emitted a malformed DwarfSpec probe report: <reason>. Probe: <probe-line>` |
| Protocol mismatch | `DwarfSpec protocol mismatch: controller expects 2, probe reported <protocol>. Check for mixed installed DwarfSpec package versions.` |
| Core-context failure | `DFHack probe did not run in a healthy core Lua context: expected core=true, reported core=<core>.` |
| Timeout-capability failure | `DFHack core Lua context is missing the required dfhack.timeout function: reported timeout=<timeout>.` |

Invocation exceptions include the resolved runner path and the cleaned exception
text. They do not claim that DFHack accepted a connection.

A malformed-response reason identifies the first grammar violation in parsing
order: invalid token, invalid field name, empty value, duplicate field, missing
required field, invalid protocol, invalid core value, or invalid timeout value.

## Bounded output excerpts

Diagnostics may include subprocess output for nonzero exits, missing markers,
multiple markers, and malformed responses. Formatting is deterministic:

1. Convert each supplied line to a safe string under a protected call so a
   failing `tostring` metamethod cannot raise a secondary formatting error. Use
   `<unprintable output>` when conversion fails.
2. Replace tab characters with one ASCII space. Replace ASCII control bytes
   `0x00` through `0x1f` and `0x7f` with `?`, then trim surrounding ASCII
   whitespace.
3. Discard empty normalized lines.
4. Limit each line to 512 bytes, including the suffix
   `...<line truncated>` when truncation occurs.
5. Retain the final eight non-empty lines in their original order. When earlier
   lines were omitted, prepend `<N earlier lines omitted>`.
6. Join rendered entries with ` | `.
7. Limit the complete excerpt to 2,048 bytes. If necessary, preserve the most
   recent output and prefix it with `<output truncated> ` within that limit.
8. Render `<no output>` when no non-empty content remains.

The limits are byte limits because Lua strings and the current subprocess
surface are byte-oriented. An implementation must not split a valid UTF-8 code
point when it truncates otherwise valid UTF-8 output.

The formatter may reproduce paths or other text already emitted by the
subprocess. It must not add command arguments, environment variables, or secret
values from controller state. Existing result persistence rules determine
whether the resulting connection failure message is written to a result file.

## Ownership boundaries

- `src/dwarfspec/host/entrypoints/probe.lua` owns safe observation and one-line
  response emission.
- `src/dwarfspec/controller/execution/transport_client.lua`, or a focused
  controller helper extracted from it, owns response parsing, output bounding,
  health checks, and connection failure construction.
- `src/dwarfspec/controller/execution/runner.lua` continues to orchestrate
  preflight before bootstrap and does not interpret probe fields.
- Test discovery continues to own canonical identity selection before runner
  orchestration. It does not diagnose DFHack connectivity.

## Verification obligations

Later implementation work must independently prove:

- probe behavior for healthy, absent, and incomplete DFHack globals;
- parser behavior for noise, missing and multiple markers, malformed fields,
  protocol mismatch, unhealthy capabilities, and unknown fields;
- exact bounded-output behavior at line-count, per-line, total-byte, control
  character, empty-output, and UTF-8 boundaries;
- preservation of connection failure kind, result state, and exit code;
- absence of bootstrap after any failed probe;
- package co-location of the controller and probe; and
- installed live success plus terminal cleanup evidence.
