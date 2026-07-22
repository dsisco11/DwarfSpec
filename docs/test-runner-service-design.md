# Test runner service and structured event design

Status: proposed

## Summary

DwarfSpec will expose its live test runner through one in-process automation
service hosted in DFHack. The external command will continue to communicate
with DFHack through `dfhack-run`. The in-game test runner will call the same
service directly and will not require a browser, a localhost listener, or a
second transport protocol.

The service will replace line-oriented runner feedback with an ordered journal
of structured events. Both consumers will use cursor-based reads over that
journal. The external command will format events for a terminal, while the
in-game screen will render them as test status, command logs, failure details,
and diagnostic snapshots.

The latest invocation result will be stored at the stable default path:

```text
<project-root>/tests/.test-results/dwarfspec/results.json
```

The file will describe the latest invocation only. A normal run will never
create a run-id-named result file unless the caller explicitly selects a
different output path.

## Goals

- Give the external command and the in-game test runner one authoritative
  service API.
- Continue using `dfhack-run` for all external-to-DFHack communication.
- Represent runner feedback as versioned, ordered, JSON-safe events.
- Preserve generation ownership, lease expiry, explicit abort, and confirmed
  LIFO cleanup.
- Allow the in-game test runner to run, observe, abort, and rerun tests without
  using a network client.
- Store only the latest result by default in an ignored directory under the
  consumer's test tree.
- Represent every invocation outcome for which a project result path can be
  resolved, including failures that happen before a native test run starts.
- Keep service requests and responses data-oriented so another transport can
  be added later without redesigning the runner.

## Non-goals

- DwarfSpec will not add a localhost server or another socket implementation.
- DwarfSpec will not replace `dfhack-run` with a direct DFHack RPC client.
- DwarfSpec will not support execution on remote machines in this design.
- DwarfSpec will not execute multiple live suites concurrently in one DFHack
  process.
- DwarfSpec will not persist default per-run history.
- DwarfSpec will not define the visual layout of the in-game test runner here.
- DwarfSpec will not replace Busted's discovery, hooks, assertions, or result
  classification.

## Locked decisions

1. The automation service lives in DFHack's core Lua context.
2. `dfhack-run` remains the only external transport.
3. The in-game test runner calls the service directly.
4. Consumers never mutate `dfhack.dwarfspec` or a run record directly.
5. Runner feedback is a structured event journal, not formatted output lines.
6. Every event has a run identity, generation, and monotonically increasing
   sequence number.
7. One DFHack process owns at most one active live run.
8. The default result file is
   `tests/.test-results/dwarfspec/results.json` beneath the project root.
9. The default result file is replaced for each invocation.
10. Explicit alternate result paths name files, not directories.
11. The result document describes runner failures as well as native test
    results.
12. Terminal results are acknowledged only after the configured persistence
    policy succeeds or an operator explicitly discards the retained result.

## Rationale

`dfhack-run` already supplies DwarfSpec's supported external connection to a
running DFHack process. Replacing it would add protocol and compatibility work
without improving the in-game screen, which already shares the host Lua
context with the test runner.

The missing abstraction is therefore not another server. It is a service that
separates run policy and state from both transport formatting and screen
presentation. Structured data at that boundary gives the terminal and the
in-game screen consistent behavior now, while remaining suitable for a future
transport adapter if remote execution becomes practical.

## System context

```text
external dwarfspec command
        |
        | dfhack-run
        v
bootstrap/status/abort/ui command adapters
        |
        v
in-process automation service <------ in-game test runner
        |
        +-- Busted host and scheduler
        +-- run state and cleanup ownership
        +-- structured event journal
        +-- latest completed result
        +-- result store
```

The adapters translate process arguments and JSON output. They contain no run
policy. The in-game screen translates player actions into service calls and
service data into views. It also contains no run policy.

## Package and project roots

The existing package and consumer boundary remains authoritative:

- `package_root` owns DwarfSpec, Busted, adapters, the scheduler, cleanup,
  reporting, and the in-game test runner implementation;
- `project_root` owns configuration, selected live specs, custom commands,
  support modules, and generated results.

Opening the in-game runner requires an initialized project session. The
external command will provide a `dwarfspec ui` entry point that resolves the
same project configuration as `dwarfspec run`, then uses `dfhack-run` to load
or focus the in-game screen with explicit package and project roots.

Once initialized, the in-game screen can start further runs directly through
the service. It reuses the normalized project session and never infers the
project root from the package location.

## Automation service

The automation service is the only public boundary over live runner state. Its
operations are conceptually:

| Operation | Purpose |
|---|---|
| `configure(request)` | Establish or refresh an explicit package/project session. |
| `catalog(request)` | Return deterministic spec identities and supported run filters. |
| `start(request)` | Create one generation-owned, nonblocking run. |
| `snapshot(run_id)` | Return the current immutable run summary. |
| `events(run_id, after_sequence)` | Return ordered events after a consumer cursor. |
| `abort(run_id, reason)` | Abort the owned run and perform emergency cleanup. |
| `acknowledge(run_id, generation)` | Confirm durable observation of a terminal result. |
| `discard(run_id, generation, reason)` | Explicitly release a retained terminal result without persistence. |
| `latest_result()` | Return the most recently completed invocation result. |
| `close_session(reason)` | Close the UI/project session when no run is active. |

These operation names describe the contract, not the final Lua calling syntax.
All requests and responses must be ordinary JSON-safe tables. They must not
expose screens, widgets, coroutines, timeout handles, cleanup actions, or other
DFHack userdata.

### Service ownership

The process-wide `dfhack.dwarfspec` entry will retain only a small compatible
service registry. Mutable implementation state stays private to the service
module. The registry contains:

- service protocol version;
- service instance identity;
- current generation;
- configured project session;
- active run identity, if present;
- unacknowledged terminal run identity, if present.

Reloading a compatible service must preserve an active run. Loading an
incompatible protocol while a run is active must fail without modifying that
run. A new start must fail before discovery or construction when another run
is active or a terminal result remains unacknowledged.

### State model

Native runs retain the following state progression:

```text
starting -> running -> cleaning -> passed
                               \-> failed

starting -> cleaning -> aborted
running  -> cleaning -> aborted
```

`passed`, `failed`, and `aborted` are terminal native states. Cleanup
confirmation is a separate required property; a nominally passing Busted run
without confirmed cleanup becomes failed.

The persisted invocation result also represents outcomes outside the native
state model, including:

- invalid project or selection;
- missing dependency;
- DFHack connection failure;
- bootstrap or status transport failure;
- external timeout;
- interruption;
- result persistence failure.

Those outcomes do not create fake native host states. They are classified by
the outer result document.

## Structured event journal

Each run owns an append-only event journal for its lifetime. The service is the
only event publisher. Event payloads are copied into the journal so later
mutation of a Busted element, diagnostic table, or run counter cannot rewrite
previous observations.

### Event envelope

Every event uses this envelope:

```json
{
  "schema": "dwarfspec.event.v1",
  "run_id": "dwarfspec-123-example",
  "generation": 7,
  "sequence": 12,
  "type": "test.finished",
  "elapsed_ms": 438,
  "payload": {
    "name": "settings screen enables notifications",
    "status": "passed",
    "duration_ms": 41
  }
}
```

Required envelope fields are:

- `schema`: exactly `dwarfspec.event.v1`;
- `run_id`: the owning external identifier;
- `generation`: the owning service generation;
- `sequence`: a one-based integer that increases by one for every event;
- `type`: a stable namespaced event type;
- `elapsed_ms`: milliseconds since the run record was created;
- `payload`: a JSON object, which may be empty.

Wall-clock timestamps are optional presentation metadata and are not used for
ordering. Sequence numbers are authoritative.

### Initial event types

| Event type | Required payload |
|---|---|
| `run.started` | normalized selection, repeat count, and options safe for display |
| `repeat.started` | repeat index and repeat count |
| `repeat.finished` | repeat index and counts |
| `test.started` | stable full test name and source identity when available |
| `test.finished` | stable full name, status, and duration |
| `problem.recorded` | kind, name, message, and optional trace |
| `command.started` | command name, subject identity, and safe arguments |
| `command.finished` | command name, status, duration, and optional snapshot reference |
| `diagnostic.recorded` | diagnostic kind and bounded JSON-safe content |
| `cleanup.started` | cleanup reason and pending action count |
| `cleanup.failed` | action name, reason, message, and optional trace |
| `cleanup.finished` | confirmation and verified mount cleanup state |
| `run.aborted` | abort reason |
| `run.finished` | native terminal state, totals, and cleanup confirmation |

Human-readable terminal lines are derived from events outside the service.
They are not stored as the primary protocol. An optional `display` field may
be added to individual payloads only when the text itself is meaningful test
data rather than protocol framing.

### Cursor reads

`events(run_id, after_sequence)` returns events whose sequence is greater than
the supplied cursor. It also returns `last_sequence`, allowing consumers to
advance even when no events are present.

Repeated reads with the same cursor return the same event values and ordering.
Reading events does not acknowledge a terminal result, renew ownership on
behalf of another consumer, or discard journal entries.

The external command renews the run lease when its status adapter successfully
reaches the service. The in-game screen does not own that lease for externally
started runs. Closing or reopening the screen therefore cannot accidentally
abort a terminal-driven command run.

### Retention

The service retains the complete journal for the active run and the most
recent unacknowledged terminal run. Once a terminal result has been persisted
and acknowledged, the service may discard its journal when a replacement run
starts.

This design intentionally provides latest-run retention, not history. A future
history feature requires an explicit storage policy and is not inferred from
the in-memory journal.

## Snapshots

A snapshot represents current state, while events represent changes. Status
responses include both so a consumer can recover after missing any number of
polls.

The snapshot contains at least:

- schema and protocol versions;
- run ID and generation;
- native state and terminal flag;
- current repeat and current test;
- current and cumulative Busted counts;
- last event sequence;
- cleanup confirmation and cleanup reason;
- verified mount cleanup state;
- host error and trace, when present;
- failure summaries.

Snapshots never contain live DFHack objects. Diagnostic component trees and
screen state are emitted as bounded JSON-safe values or referenced by an event
sequence.

## `dfhack-run` transport adapters

`bootstrap.lua`, `status.lua`, and `abort.lua` become thin adapters over the
service. A UI bootstrap adapter will support `dwarfspec ui`.

The external transport will continue to emit one canonical prefixed JSON line
so unrelated DFHack console output cannot be mistaken for protocol data:

```text
DWARFSPEC_JSON { ... }
```

The JSON payload will use `dwarfspec.transport.v2` and contain:

```json
{
  "schema": "dwarfspec.transport.v2",
  "protocol": 2,
  "run_id": "dwarfspec-123-example",
  "generation": 7,
  "snapshot": {},
  "events": [],
  "last_sequence": 12
}
```

`OUTPUT`, `DETAIL`, `HOST_ERROR`, and similar formatted protocol lines become
diagnostic compatibility output only and can be removed after the version 2
consumer is authoritative. The canonical JSON line remains sufficient to
reconstruct all command feedback.

The transport parser validates schema, protocol, run ID, generation, event
sequence continuity, and required fields before exposing data to the runner.
A malformed response retains the current recovery behavior: attempt an
explicit native abort without hiding the original transport failure.

## External command behavior

An external `dwarfspec run` invocation performs this sequence:

1. Resolve the project, configuration, selection, result path, and
   `dfhack-run` executable.
2. Write a new `starting` invocation result to the stable result path.
3. Probe DFHack's core Lua context.
4. Bootstrap the configured service and start the run.
5. Format returned structured events for the terminal.
6. Poll status using the last consumed event sequence.
7. On interruption, timeout, or malformed transport output, request an abort.
8. Persist the terminal invocation result.
9. Acknowledge the native terminal generation only after successful
   persistence.
10. Return the existing classified process exit code.

If persistence fails, the command reports a host failure and does not
acknowledge the terminal generation. This preserves the retrievable result and
prevents a replacement run from silently destroying it. A later retry can
persist and acknowledge the same generation. An explicit discard operation is
available for operator-directed recovery when persistence cannot be repaired.

## In-game test runner

The in-game screen is a direct service client. It does not parse transport
lines and does not shell out to `dfhack-run`.

The screen will be able to:

- display the configured project and service health;
- list deterministic spec identities;
- select spec identities and configure supported name, tag, and category
  filters for a run;
- start a selected run;
- observe current state and structured events;
- abort the active run;
- rerun the previous request or only previously failed test names;
- show failure details and command logs;
- show diagnostic snapshots associated with command events;
- load the stable latest result after the in-memory run is no longer present.

The screen maintains only presentation state and event cursors. It does not
own cleanup actions, run generations, Busted objects, or result persistence.
Closing the screen leaves an active run under its existing owner. Starting a
run from the screen makes the configured in-process project session the owner
and keeps the same lease and cleanup guarantees.

## Result storage

### Default path

The default result file is:

```text
<project-root>/tests/.test-results/dwarfspec/results.json
```

The path is beneath the consumer project, never the package root. The
`.test-results` directory is expected to be ignored; DwarfSpec's own
`.gitignore` already ignores that directory recursively.

`--results PATH` names an exact file. A relative path is resolved beneath the
project root. This intentionally replaces the earlier directory-valued option
semantics. `--no-results` selects a no-persistence policy for callers that do
not need the latest-result contract.

### Replacement policy

Default persistence never incorporates a run ID into the filename. Each
invocation replaces `results.json`. DwarfSpec may use a temporary sibling file
during a safe replacement, but it must clean that temporary file and must not
retain it as history.

At invocation start, the previous result is replaced by a `starting` document.
This prevents an earlier pass from appearing to describe a new invocation
that failed before bootstrap. The record is replaced again when the invocation
reaches a terminal outcome.

If the process terminates without a final write, the remaining `starting`
record correctly communicates that the latest invocation did not complete.

### Result schema

The persisted document uses `dwarfspec.result.v2`:

```json
{
  "schema": "dwarfspec.result.v2",
  "run_id": "dwarfspec-123-example",
  "state": "failed",
  "terminal": true,
  "exit_code": 6,
  "project_root": "D:/project",
  "selection": {
    "identities": ["tests/settings.ds.lua"]
  },
  "started_at": "2026-07-22T12:00:00Z",
  "finished_at": "2026-07-22T12:00:02Z",
  "error": null,
  "host_report": {},
  "events": []
}
```

The outer `state` describes the whole invocation. It may contain the stable
native states or a runner classification such as `dependency_error`,
`connection_error`, `host_error`, `timeout`, or `interrupted`.

`host_report` contains the final native snapshot when the host produced one.
It is `null` for failures before native bootstrap. `events` contains the
ordered latest-run journal that was available to the persistence owner.

Sensitive environment values, arbitrary process environment contents, and
raw DFHack objects are never persisted. Project and spec paths are normalized
for stable display but are not treated as portable remote identities.

## Persistence ownership

Exactly one component owns result writes for an invocation:

- for `dwarfspec run`, the external command owns starting and terminal writes;
- for a run started from the in-game screen, the in-process service owns those
  writes;
- transport adapters never write results independently.

The run request records its persistence owner and exact result path. Recovery
abort does not transfer ownership. The owner writes the terminal result before
acknowledging it to the service.

When `--no-results` is selected, the persistence policy succeeds without a
file write after the owner has received the complete terminal snapshot and
event journal. The owner can then acknowledge the terminal generation. A
write failure under a file-backed policy is not equivalent to `--no-results`.

## Cleanup, leases, and acknowledgement

Structured events do not weaken existing cleanup behavior. Example
completion, assertion failure, command timeout, external timeout, lease
expiry, explicit abort, and early unmount continue to drain owned resources in
strict LIFO order.

Cleanup completion emits `cleanup.finished` only after the existing lifecycle
probe confirms that no active mount, screen, subject, scheduler, wait, pointer,
or timeout remains. `run.finished` follows cleanup and reports the same
confirmation.

An external run renews its lease through successful status requests. If the
external process disappears, lease expiry aborts the run and performs cleanup.
An in-game-owned run uses a service-owned heartbeat that is independent of
whether its screen is currently visible.

Terminal observation and terminal acknowledgement are separate:

- observation reads the terminal snapshot and events;
- persistence writes the complete result document;
- acknowledgement permits the service to replace the retained terminal run.

An explicit discard is a separate operator action. It records a bounded
reason, releases the retained terminal generation, and is never performed as
automatic recovery from a write failure.

## Concurrency

Live DwarfSpec runs remain serialized per DFHack process. Tests share global
screen, pause, pointer, frame scheduler, and mount state, so concurrent live
runs in one process would violate isolation even if the transport accepted
concurrent requests.

The service returns a classified busy result when another run is active or an
unacknowledged terminal result is retained. The in-game screen can display the
owner and current state but cannot bypass the ownership check.

Parallel execution may later be added across separate DFHack processes. That
would require an explicit target abstraction and separate project sessions;
it does not change the single-run invariant inside each process.

## Future transport compatibility

Remote execution is intentionally deferred. The design leaves a narrow door
open by requiring:

- JSON-safe service requests and responses;
- stable string identities instead of userdata;
- versioned snapshots, events, and results;
- cursor-based event retrieval;
- explicit start, abort, persistence, and acknowledgement operations;
- explicit terminal discard instead of implicit result loss;
- no UI logic inside service methods.

A future agent can translate a secure transport into these service operations.
It must also solve authentication, encryption, project synchronization,
package deployment, and remote path identity. Enabling DFHack's unrestricted
remote command listener is not considered a DwarfSpec remote execution design.

## Compatibility

The existing CLI command names and exit-code meanings remain stable. Terminal
text may become clearer, but the same test, dependency, connection, host,
timeout, and abort classifications remain available.

The `dwarfspec.run.v1` native report can be accepted during transition, but
new adapters and result persistence use the version 2 snapshot, event, and
result schemas. Schema changes require an explicit version increment; readers
must reject unknown major versions instead of guessing.

The existing run ID continues to correlate external commands, native state,
events, results, and diagnostics. Generation remains required to prevent a
stale callback or consumer cursor from referring to a replacement run with a
reused ID.

## Proposed module boundaries

The implementation is expected to converge on boundaries similar to:

| Module | Responsibility |
|---|---|
| `dwarfspec.automation.service` | Public service operations and process-wide registry compatibility. |
| `dwarfspec.automation.events` | Event construction, validation, copying, sequencing, and cursor reads. |
| `dwarfspec.automation.host` | Busted execution, scheduling, state transitions, and cleanup. |
| `dwarfspec.automation.output_handler` | Translation from Busted callbacks into service events. |
| `dwarfspec.automation.result_store` | Stable result schema and safe replacement writes. |
| `dwarfspec.automation.ui` | In-game test runner presentation and input handling. |
| bootstrap/status/abort adapters | `dfhack-run` argument and JSON transport translation. |
| `dwarfspec.runner` | External orchestration, event formatting, recovery, and exit classification. |
| `dwarfspec.report` | Transport/result schema validation and external persistence support. |

Exact filenames may change, but service, events, host execution, UI,
transport, and persistence must remain separate responsibilities.

## Verification requirements

### Offline contracts

- Event sequences start at one, are contiguous, and are immutable after
  publication.
- Cursor reads are deterministic, resumable, and do not duplicate events.
- Every Busted outcome produces the expected structured events and counts.
- Cleanup errors produce events without hiding the original failure.
- Snapshot and event values contain no userdata or cyclic tables.
- Run ID and generation mismatches are rejected.
- Overlapping starts and unacknowledged replacement starts are rejected before
  discovery or construction.
- Transport version 2 validates required fields and rejects malformed event
  sequences.
- The default path resolves to
  `tests/.test-results/dwarfspec/results.json` beneath the project root.
- Two default runs leave one result file and the second result replaces the
  first.
- A pre-bootstrap failure replaces an earlier successful result.
- Explicit result paths name files, and `--no-results` performs no write.
- Result persistence failure prevents terminal acknowledgement.
- Explicit discard releases only the exact retained run ID and generation and
  records its reason.

### Live DFHack contracts

- The external command streams formatted version 2 events through
  `dfhack-run` and returns the established exit codes.
- The in-game screen opens or focuses through `dwarfspec ui` and uses the same
  configured project session as the CLI.
- The screen observes a run started externally without affecting its lease.
- A screen-started run executes, reports events, persists the stable result,
  and confirms cleanup.
- Closing the screen does not leak or abort a correctly owned active run.
- Timeout, interruption, explicit abort, assertion failure, host error, and
  cleanup failure all retain their existing cleanup guarantees.
- A lost external command causes lease expiry and confirmed cleanup.
- A terminal result remains available until persistence and acknowledgement
  succeed.

### Packaging and documentation contracts

- All new service, event, result-store, UI, and adapter modules are included in
  the rockspec.
- The source checkout and installed rock resolve package and project roots
  identically.
- CLI help documents the exact result-file semantics.
- User documentation describes the in-game runner as an in-process client, not
  a localhost service.
- The default result directory is documented as generated and ignored.

## Deferred decisions

The following details require separate focused designs:

- the in-game screen layout and navigation model;
- the component-tree snapshot schema and size limits;
- whether command snapshots are embedded or referenced within the latest
  result;
- event-journal size limits for unusually large suites;
- multi-process target discovery and scheduling;
- secure remote agents and project synchronization.

None of these deferred decisions changes the service, event ordering, result
location, stable filename, or single-run ownership established here.
