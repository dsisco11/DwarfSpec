# Verified command execution architecture proposal

## Status

This document proposes a foundational execution model for all public DwarfSpec
commands. It is an architecture proposal, not an implementation checklist and
not a description of shipped behavior.

The proposal adopts Cypress-like command actionability, finite command
deadlines, one-shot mutation, and retryable verification without adopting
Cypress's browser-specific command queue. DwarfSpec remains a synchronous Lua
API from the test author's perspective, with cooperative waits driven by the
existing in-process scheduler.

## Decision summary

Every public command executes through one run-scoped command runner and has:

- a finite, configurable wall-clock deadline;
- an explicit read-only preflight gate;
- one primary execution operation;
- intrinsic verification whenever the command's framework-level effect is
  observable; and
- optional caller-supplied verification for product-specific outcomes.

Preflight and verification may retry within the shared deadline. Primary
execution runs exactly once unless a command definition explicitly proves that
it is safe and useful to retry. No initial built-in mutating command will opt
into execution retry.

A caller is not required to supply a verification callback. DwarfSpec will
encourage one for generic interaction commands, but omitting it remains valid.
The command trace and documentation must distinguish intrinsic verification
from a caller-supplied semantic postcondition so that a completed render is not
misrepresented as proof of an application result.

The architecture is designed and implemented as one coherent system, but
commands migrate in bounded groups. Exhaustive unit, package, and live
qualification runs occur at risk-based integration checkpoints rather than
after every mechanical command conversion.

## Motivation

The current command surface has several good but inconsistent execution
mechanisms:

- scheduler waits support wall-clock timeouts and frame budgets;
- mounted mutations propagate execution errors and usually wait for a later
  completed render;
- selected state setters read native state back after mutation;
- save-game workflows poll exact intermediate and terminal states;
- the cleanup registry provides LIFO cleanup and terminal cleanup evidence;
- command observation records command start, finish, duration, and failure;
  and
- project-defined commands are isolated and bound to the run-scoped `ds`
  namespace.

These mechanisms do not form one command contract. Generic keyboard, text,
mouse, and click commands treat non-throwing input dispatch followed by a
completed render as success. A render can complete even when input was ignored,
was unhandled, targeted an unexpected screen, or produced no meaningful state
change. Other commands perform stronger readback, while custom commands are
bare callbacks with no common gate, deadline, verification, or cleanup policy.

This creates three problems:

1. A command can return successfully without proving even the strongest effect
   that its public contract could reasonably guarantee.
2. Failures do not consistently identify whether readiness, execution,
   verification, or cleanup was responsible.
3. Each new command must assemble scheduler, render, diagnostics, and cleanup
   behavior independently, increasing implementation and review cost.

## Goals

- Give every public command one observable lifecycle and one finite deadline.
- Retry readiness and observation without replaying unsafe mutations.
- Verify every framework-owned effect that can be defined generically.
- Allow, but do not require, callers to attach product-specific verification.
- Preserve Busted as the owner of test structure, assertions, and result
  classification.
- Preserve DwarfSpec's run-scoped cleanup, executor quarantine, and terminal
  cleanup evidence.
- Make command failures precise, bounded, and useful without requiring a live
  debugger.
- Give built-in and project-defined commands the same safe extension model.
- Keep the root `ds` module a composition facade instead of a second command
  implementation layer.
- Permit incremental migration without repeated exhaustive validation for
  low-risk mechanical changes.
- Provide a reusable foundation for the managed native-fixture commands.

## Non-goals

- Replacing Busted with a DwarfSpec assertion framework.
- Copying Cypress's JavaScript command queue, Promise model, DOM semantics, or
  fluent chain retry algorithm.
- Automatically inferring product-specific intent from generic input.
- Retrying clicks, text entry, save transitions, fixture creation, or other
  mutations by default.
- Making arbitrary synchronous Lua interruptible. Native and Lua execution must
  cooperate with the scheduler to be time-bounded safely.
- Rewriting controller discovery, transport, result persistence, TestBed, or
  the host service when their existing contracts can carry the new evidence.
- Treating a completed render as proof that rendered content is correct.
- Requiring a full unit, live, syntax, and package qualification cycle after
  every individual command is mechanically migrated.

## Terminology

### Command definition

A command definition is immutable framework or project configuration that
describes a command's name, kind, normalization, preflight, execution,
verification, timeout default, and diagnostic policy.

### Command invocation

A command invocation is one run-owned execution of a definition with normalized
arguments, a fixed deadline, command identity, target identity, cleanup
checkpoint, and trace.

### Preflight gate

The preflight gate is a read-only predicate that resolves current native or
mounted state and determines whether primary execution is safe to attempt. A
not-ready result is retried. A fatal result or unexpected error terminates the
command immediately.

### Primary execution

Primary execution performs the command's logical mutation or observation. It
runs once for mutating commands. It returns a private receipt and a public
result instead of requiring verification to infer what was attempted.

### Intrinsic verification

Intrinsic verification checks an effect promised by the DwarfSpec command
contract. Examples include exact state readback, pointer-coordinate readback,
confirmed render completion, current mount ownership, or exact loaded save
identity.

### Caller verification

Caller verification is an optional callback supplied with a command invocation.
It describes a product-specific effect that DwarfSpec cannot infer, such as a
dialog becoming visible or a route list changing. Its absence does not make an
invocation invalid.

### Receipt

A receipt is an immutable, plain-data record produced by primary execution for
verification and diagnostics. It contains stable identifiers and scalar
snapshots, never mutable native pointers that may become invalid across frames.

### Deadline

A deadline is an absolute monotonic timestamp calculated once after synchronous
argument normalization succeeds. Every cooperative wait receives the remaining
duration. No timed command stage resets the timeout.

## Design principles

### Retry observation, not mutation

Preflight and verification are read-only and retryable. Primary mutation is
one-shot. This prevents a delayed UI update from causing duplicate clicks,
duplicated text, repeated save transitions, or multiple native resources.

### Verify only declared effects

DwarfSpec must not claim more than it can observe. `ds.redraw()` can prove that
a later render completed. It cannot prove that a particular label is correct.
`subject:click()` can prove that the selected target was actionable and that
input was dispatched through the intended ingress. It cannot know which
product behavior the click was meant to trigger.

### One deadline owns the timed command lifecycle

Argument normalization is bounded, synchronous, non-yielding validation and
defensive copying. It occurs before the timed command lifecycle and reports an
immediate invocation error when it fails. Starting the deadline earlier would
measure normalization after it returns but could not interrupt a defective
synchronous normalizer. Once normalization succeeds, readiness, primary
execution, render waits, intrinsic verification, and caller verification share
one deadline. A slow preflight therefore leaves less time for verification
instead of silently multiplying the configured timeout.

### Cleanup outlives an expired command

The command deadline does not suppress cleanup. Cleanup executes under the
existing example and executor recovery contract with its own bounded lifecycle.
An expired command can therefore fail and still restore or remove owned state.

### Register ownership before mutation

Any command that creates or temporarily changes reversible state establishes
cleanup ownership before the state can escape. When allocation and publication
cannot be separated, the command reserves a pending ownership entry and later
attaches the stable identity.

### Re-resolve live targets

Preflight and verification re-resolve subjects and native identities from their
stable descriptors. They do not retain an assumed-live widget or DF userdata
across scheduler yields. The final successful preflight observation is checked
again immediately before primary execution when a target can become stale.

### Public commands do not call public commands internally

Composite behavior uses internal operations or workflow steps. This avoids
nested independent deadlines, duplicate command events, repeated cleanup
registration, and misleading success records. For example, `click()` may use
the pointer-placement operation internally, but it does not invoke a second
public `move_pointer()` command.

### Nested read-only commands inherit their parent invocation

A query or assertion invoked by caller verification inherits the parent's
absolute deadline, cancellation state, and command identity. It appears as a
child command event and cannot extend or reset the parent timeout. Mutating
public commands are rejected from preflight and verification because those
stages must remain read-only. Internal workflow steps use the same child-event
model without becoming independent public invocations.

## Command categories

All categories use the common runner, deadline, trace, and failure schema. The
categories specialize retry and verification behavior instead of forcing
meaningless callbacks into every command.

| Kind | Primary behavior | Retry behavior | Verification expectation |
| --- | --- | --- | --- |
| Query | Observe current state | Its read-only primary observation may return pending and retry | Validate and return a stable observation, including a successful `nil` when declared |
| Assertion | Observe a condition | Its read-only primary observation retries until ready | The assertion observation is the terminal condition |
| Action | Perform input or another one-shot mutation | Retry preflight and verification only | Verify framework effects; caller verification is optional |
| State setter | Change reversible state | Retry preflight and readback only | Exact state readback is intrinsic |
| Workflow | Execute ordered internal steps | Each step gates once under the parent deadline | Verify every declared intermediate and terminal state |
| Fixture | Create or reserve owned native state | Retry readiness and readback only | Verify identity/state after creation and absence/restoration during cleanup |

`ECommandKind` contains exactly `QUERY`, `ASSERTION`, `ACTION`, `STATE_SETTER`,
`WORKFLOW`, and `FIXTURE`. A definition selects exactly one kind. Recurrence,
evidence capture, subject fluency, and cleanup lifetime are orthogonal traits,
not hybrid command kinds.

Every definition has an explicit preflight function. Commands with no dynamic
readiness requirement use the shared always-ready predicate so the lifecycle
and trace remain uniform.

Every definition has a primary execution function. For queries and assertions,
that function performs the read-only observation and returns `ready`, `pending`,
or `fatal`. A query uses `ready(nil, evidence)` when `nil` is a successful result,
so ordinary misses are not confused with retryable pending state. For actions,
state setters, workflows, and fixtures, primary execution returns `executed`
and is never retried by the runner.

Intrinsic verification is required when the public contract declares an
independently observable effect. A definition may explicitly declare that its
execution receipt is its complete intrinsic evidence when no stronger generic
effect exists. Caller verification remains optional in every case.

## Command definition contract

The following shape is illustrative; exact Lua names may change during
implementation:

```lua
---@class dwarfspec.CommandDefinition
---@field name string
---@field kind dwarfspec.ECommandKind
---@field normalize fun(arguments: table): any
---@field preflight fun(context: dwarfspec.CommandContext, request: any): dwarfspec.GateResult
---@field execute fun(context: dwarfspec.CommandContext, request: any, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field verify? fun(context: dwarfspec.CommandContext, request: any, receipt: any): dwarfspec.GateResult
---@field default_timeout_ms? integer
---@field diagnostics? fun(request: any, receipt: any): table
```

The registry validates definitions before a test begins:

- names are nonempty and do not conflict;
- kinds are supported immutable enum values;
- normalize, preflight, and execute are callable;
- normalize is bounded, synchronous, and non-yielding;
- verify and diagnostics are callable when present;
- timeout defaults are positive finite integers;
- definitions cannot replace reserved built-in commands; and
- diagnostic adapters return plain bounded data.

Definition tables are copied or frozen at registration so a consumer cannot
change command behavior while a run is active.

## Gate result protocol

Preflight and intrinsic verification return one of three explicit outcomes:

```lua
command.ready(value, evidence)
command.pending(reason, evidence)
command.fatal(message, evidence)
```

- `ready` advances the command and may carry a freshly resolved value.
- `pending` yields to the scheduler and retries while time remains.
- `fatal` stops immediately because retry cannot make the request valid.
- an unexpected callback error is fatal and preserves its traceback.

Evidence must be bounded plain data suitable for command diagnostics. The
runner retains the most recent pending reason and observation for timeout
reports.

Built-in definitions use this explicit protocol so programming defects are not
mistaken for ordinary not-ready state.

## Primary execution result

Primary execution returns a private structured result:

```lua
command.executed(public_result, receipt)
```

The public result preserves the command's documented return value. The receipt
is available only to intrinsic and caller verification and to bounded failure
diagnostics. Returning `false` from a native adapter is not silently interpreted
as success; each definition must explicitly normalize its native acknowledgement
into either a receipt or an execution failure.

If primary execution throws or returns a declared failure, verification does
not run. Prearmed cleanup transactions remain owned. Command-lifetime
transactions are expended by the command's finally boundary, while
example-lifetime transactions remain pending for manual execution or teardown.

## Caller-supplied verification

### Optional contract

Caller verification is always optional. Existing calls remain valid without a
callback:

```lua
ds.get('submit'):click()
```

Tests are encouraged to provide verification when a generic action has a known
product outcome:

```lua
ds.get('submit'):click(nil, {
    timeout_ms=5000,
    verify=function()
        return ds.search({text='Saved'})
    end,
})
```

The final public API should use a trailing command-options argument, separate
from logical command options. This avoids reserving generic keys inside domain
option records and preserves existing positional calls through overloads.

```lua
---@class dwarfspec.CommandOptions
---@field timeout_ms? integer
---@field description? string
---@field verify? fun(observation: dwarfspec.CommandObservation): any
```

Where a method already accepts an options table, the command-options table is a
new final argument. Examples include:

```lua
subject:mouseWheel(wheel_options, command_options)
ds.setViewPos(position, origin, command_options)
ds.mountSaveGame(directory_name, command_options)
```

The exact overloads must be declared in `ds.d.lua` before migration is complete.

### Callback semantics

The verification callback receives a read-only observation containing:

- the command name and kind;
- the stable target identity, when present;
- the public execution result;
- a copied receipt;
- the attempt count;
- elapsed and remaining milliseconds; and
- the most recent intrinsic verification evidence.

A truthy callback result passes verification. `false` or `nil` is pending and
is retried. A callback assertion or error is retained as the latest failed
observation and retried until the deadline, matching the useful behavior of a
Cypress assertion callback. The final timeout includes the last bounded error
and traceback. Documentation must warn that ordinary programming errors inside
the callback will also be retried until timeout.

Caller verification cannot disable or weaken intrinsic verification. It runs
after intrinsic verification passes, under the same remaining deadline. Its
return value does not replace the command's public result.

Read-only public queries and assertions called by the callback automatically
inherit the active verification invocation. Their events are children of the
parent command, and their effective deadline is the parent's remaining time.
Attempting a mutating public command from preflight or verification is a fatal
contract error.

### No implicit semantic claim

When caller verification is absent, command success means only that all
intrinsic guarantees passed. The command trace records one of:

- `verification=intrinsic_and_caller`;
- `verification=intrinsic_only`; or
- `verification=execution_receipt_only`.

Generic action documentation must say which intrinsic guarantees exist and
recommend an explicit semantic postcondition.

## Timeout and scheduling contract

### Configuration

The shared default belongs in project configuration:

```lua
return {
    settings={
        command={
            timeout_ms=10000,
        },
    },
}
```

Timeout precedence is:

1. invocation `CommandOptions.timeout_ms`;
2. `settings.command.timeout_ms`;
3. command-definition `default_timeout_ms`;
4. the framework default of 10,000 milliseconds.

The project-wide setting exists so a consumer can adapt the complete suite to a
consistently slower or faster live environment without editing every command
call. A command-definition default expresses a command's recommended baseline,
but it never prevents a project or invocation from overriding that baseline.

Every resolved timeout is a positive finite integer. The finalized command
contract does not allow `false` or an unlimited timeout. Existing
`settings.wait.timeout_ms` and wait-command `timeout_ms=false` behavior require
a documented compatibility window. During that window,
`settings.wait.timeout_ms` supplies the command default when
`settings.command.timeout_ms` is absent. Unlimited waits should emit a bounded
deprecation diagnostic and remain protected by the enclosing run lease until
their public removal.

The compatibility window ends before old command execution paths are removed.
Final configuration validation rejects `timeout_ms=false`, and
`settings.wait.timeout_ms` no longer supplies command defaults after that
removal checkpoint.

Frame budgets remain optional secondary safeguards for commands defined in
terms of frames. They do not replace the wall-clock deadline.

### Shared deadline

The runner obtains time from an injected monotonic clock and calculates the
deadline once. Scheduler calls receive remaining milliseconds, rounded in a
single documented direction. If no time remains before primary execution, the
command fails without mutating. If execution returns after the deadline, the
runner records the receipt, reports an execution-timeout failure, and preserves
cleanup ownership; it does not claim success merely because synchronous code
eventually returned.

### Cooperative limitation

Lua cannot safely interrupt arbitrary synchronous native code. Therefore:

- primary execution must be nonblocking and bounded;
- polling belongs in preflight or verification;
- long workflows must yield through the command context scheduler;
- callbacks that can loop indefinitely are invalid command implementations;
  and
- the external lease and executor quarantine remain last-resort recovery, not
  ordinary command timeout mechanisms.

The command authoring documentation must make this limitation explicit.

## Command runner lifecycle

For each invocation the runner performs the following operations:

1. Resolve the definition and validate invocation-level command options.
2. Normalize and defensively copy logical arguments synchronously.
3. Resolve the finite timeout and create the timed invocation deadline.
4. Publish command-started evidence with sanitized arguments.
5. Mark a cleanup checkpoint and construct the command context.
6. Poll preflight until ready, fatal, cancelled, or timed out.
7. Revalidate volatile target identity immediately before execution. A
   recoverable not-ready result returns to the preflight loop under the same
   deadline; removal, replacement, or another nonrecoverable identity change is
   fatal.
8. Prearm required cleanup or pending ownership.
9. For a query or assertion, poll its read-only primary observation until it
   returns ready, fatal, cancelled, or timed out. For every mutating kind,
   execute the primary operation exactly once and capture its receipt.
10. Poll intrinsic verification when defined.
11. Poll caller verification when supplied.
12. Refresh retained subjects only after successful verification.
13. Publish terminal command evidence.
14. Return the original public result.

On any failure, the runner records the failing stage and latest evidence. It
then expends any still-pending command-lifetime cleanup transactions without
draining example-lifetime transactions. Cleanup failure is combined with, and
never replaces, the original command failure. Remaining example transactions
stay registered for manual execution or automatic test teardown.

## Command context

The run-scoped command context exposes only bounded capabilities:

- monotonic time and remaining deadline;
- cooperative frame, tick, event, and predicate waits;
- cancellation state;
- current mount and stable-subject resolution;
- command-local cleanup checkpoint and ownership registration;
- render-generation capture and observation;
- safe diagnostic recording;
- internal workflow-step execution; and
- immutable run and command identity.

It does not expose the host service, controller transport, mutable command
registry, or unrestricted result publisher. Driver modules continue to avoid
imports from `dwarfspec.host`.

## Workflows and internal steps

Commands such as `mountSaveGame()` are workflows rather than single native
actions. A workflow has one public command identity, one deadline, and one
terminal result. It contains named internal steps with their own preflight,
one-shot execution, and verification callbacks.

For example, save loading can retain the existing logical sequence:

1. verify the title main menu;
2. execute Continue once and verify the world list;
3. select the exact world once and verify its save list;
4. select the exact save once;
5. verify the map-loaded event, loaded-world state, exact save directory, and
   disappearance of the load screen.

Steps share the parent's remaining deadline. They appear as nested trace events
but do not create independent public command results or reset timeout budgets.

## Cleanup and transactional ownership

The cleanup registry owns executable cleanup transactions rather than bare
callbacks. Registration returns a handle with an explicit lifecycle:

```lua
---@class dwarfspec.CleanupTransaction
---@field execute fun(self: dwarfspec.CleanupTransaction, reason?: string): boolean
---@field isPending fun(self: dwarfspec.CleanupTransaction): boolean
```

A transaction contains a label, restore operation, required verification
operation, stable cleanup evidence, and one of `pending`, `running`, `complete`,
`failed`, `abandoned`, or `unconfirmed`. The first two states are nonterminal;
the remaining four are terminal dispositions. `abandoned` is restricted to an
internal prearmed reservation for which no mutation or publication occurred.
`unconfirmed` means interruption or host loss prevented the framework from
establishing a normal cleanup outcome. Caller registrations have example
lifetime. Internal registrations may instead have command lifetime for
transient input flags or similar state.

Calling `transaction:execute()` manually removes the pending transaction from
the active LIFO registry before invoking restore and verification. The handle
then records `complete` or `failed` and is expended. Repeated execution is
idempotent: it reports that no pending work was executed and never invokes the
callbacks again. A manual failure is recorded in authoritative cleanup evidence
and propagates to the test; it is not silently retried during teardown.

At test teardown, the cleanup system automatically executes every transaction
that remains pending in strict LIFO order. One failure does not prevent later
transactions from being attempted. Teardown combines all transaction failures
with lifecycle probes before setting `cleanup_confirmed`.

The public cleanup API does not expose cancellation without execution. An
internal pending ownership reservation may be abandoned only when the command
proves that no mutation or publication occurred. Once a resource or reversible
state is published, its transaction must be executed manually or remain pending
for teardown.

State setters capture their first inherited baseline and register an example
transaction before mutation. Fixture commands reserve a pending transaction
before native construction and attach stable identity evidence after
publication. Command-lifetime transactions are automatically expended in the
command's finally boundary. A command failure does not drain unrelated or
example-lifetime transactions because callers may catch the failure and
continue the test.

Every cleanup transaction that mutates external state has an independent
verification operation. Cleanup verification is not optional because
`cleanup_confirmed` must remain authoritative. Cleanup uses stable identities
and scalar snapshots, continues after individual failures, and aggregates all
labeled failures.

An expired verification deadline does not discard the execution receipt. The
receipt remains available to its registered transaction so partial or
successful mutation can be reversed even when the command never returned to
test code.

### Cleanup history and result reporting

The active LIFO registry and cleanup history have different responsibilities.
Each test attempt owns its own active registry and mutable cleanup execution
index. The registry contains only transactions that remain eligible for
automatic execution. The execution index retains the in-process handles,
private receipts, and current states required to execute those transactions;
it is never shared between test attempts. Removing a transaction from the
active registry therefore means only that teardown must not execute it again.
Its already-published lifecycle events remain in the service journal.

Registration assigns a stable transaction ID and registration ordinal before
the transaction can protect or publish mutable state. The transaction ID is
unique within the run, while the registration ordinal is local to the owning
test attempt. Its safe event projection contains only bounded,
serialization-safe data:

- test and attempt identity;
- transaction ID, registration ordinal, label, and lifetime;
- owning command invocation ID when one exists;
- current state and the reason or trigger for execution;
- registration, execution-start, and completion timing;
- restore and verification outcomes;
- a bounded evidence summary or failure reference; and
- terminal disposition.

Callbacks, native userdata, mutable receipts, and unrestricted arguments never
enter the journal. The executable handle and mutable execution index may retain
richer in-process state, but result consumers receive only the safe projection.

The automation service's physically run-scoped event journal is the sole
authoritative cleanup history. Every transaction lifecycle event carries the
owning test-attempt ID, repeat index, stable test identity, transaction ID, and
attempt-local registration ordinal. Consumers partition the journal by that
attempt identity; transactions from different tests or repeated attempts never
share ownership or result sets. Service-owned run cleanup remains represented
by separate run-level cleanup events and is never attributed to an arbitrary
test attempt.

The service event journal gains transaction-level lifecycle events sufficient
to reproduce the ledger without inspecting the active registry:

- `cleanup.transaction_registered` records identity, label, lifetime, owner,
  and registration order;
- `cleanup.transaction_started` records whether execution was manual,
  command-finally, or teardown initiated;
- `cleanup.transaction_finished` records `complete`, `failed`, or
  `unconfirmed`, duration, restore outcome, verification outcome, and any
  failure reference; and
- `cleanup.transaction_abandoned` records the exceptional internal-only case
  where a prearmed reservation is safely discarded after proving that no
  mutation or publication occurred.

If host loss or interruption prevents a registered transaction from reaching
one of those normal dispositions, terminalization records it as `unconfirmed`
rather than silently omitting it and publishes exactly one corresponding
`cleanup.transaction_finished` event. A terminal test attempt therefore reports
every registered transaction with exactly one disposition: `complete`,
`failed`, `abandoned`, or `unconfirmed`. Repeated manual execution does not add
a second terminal event.

### Test-attempt ownership and finalization

A test-attempt identity becomes active before its attempt-local setup hooks and
remains active through the test body and attempt-local teardown hooks. Every
caller or command cleanup transaction created during that interval is
attributed to that identity. Public cleanup registration requires an active
test attempt and is rejected from suite-level or run-level hooks that do not
have one. Service-owned run cleanup remains a separate run-level concern and
does not appear in a test attempt's transaction array.

After attempt-local teardown hooks return, registration closes and automatic
cleanup executes every transaction that remains pending. DwarfSpec then
terminalizes interrupted transactions, materializes the attempt's
`cleanup_transactions` result, and only afterward publishes `test.finished`.
The event's behavior status remains distinct from cleanup disposition; failed
or unconfirmed cleanup is reported separately and still contributes to the run
failure and quarantine rules. If interruption prevents the ordinary test
callback from finishing, run terminalization still synthesizes the attempt
result and marks every unresolved transaction `unconfirmed` before
`run.finished`.

Before publishing `test.finished`, the service's test-attempt finalizer folds
only that attempt's authoritative transaction events into a
`cleanup_transactions` array ordered by registration ordinal. The service
stores that materialized projection at
`host_report.test_attempts[].cleanup_transactions` in the owning attempt. The
projection is a convenience for completed-result consumers, not a second source
of truth.

The controller validates that projection against the complete journal and
persists it unchanged; it does not independently interpret cleanup behavior.
Result-schema validation rejects duplicate IDs, missing terminal dispositions,
inconsistent journal/result outcomes, or a transaction attributed to the wrong
test attempt. The persisted run result retains the complete event journal and
these per-attempt projections, allowing later result-file readers to inspect
the same history.

The service publishes these events through its existing append-only journal and
cursor APIs. Live consumers can therefore observe registration and state changes
by folding the selected attempt's events without polling private cleanup
objects. Completed-result consumers use the service-materialized projection.
Retained-run inspection continues to expose the complete authoritative history
for the lifetime of the service instance.
Acknowledgement releases the outstanding-run admission gate but does not erase
the read-only session record.
Result persistence derives from the same terminal service snapshot and journal;
there is no separate UI-only cleanup channel or second source of truth.

The new transaction events and per-attempt result projection require a coordinated
protocol revision. The implementation bumps the service/event/result schema
versions together, updates validators and controller interpretation, and rejects
mixed clients and services through the existing protocol negotiation boundary.
It does not write transaction events into an older schema whose consumers cannot
validate their lifecycle.

Successful cleanup remains absent from high-level warning and status surfaces.
That presentation rule does not hide the history: an on-demand cleanup trace or
test-attempt inspector may enumerate successful, failed, abandoned, and
unconfirmed transactions. Failures and unconfirmed transactions remain
prominent without requiring the UI to calculate cleanup precedence itself.

## Diagnostics and command events

The command observer expands from start/finish reporting to stage-aware events.
The exact protocol may aggregate repeated pending observations, but it must be
able to represent:

- command started;
- preflight pending, passed, fatal, or timed out;
- execution started, completed, failed, or exceeded its deadline;
- intrinsic verification pending, passed, failed, or timed out;
- caller verification pending, passed, failed, or timed out;
- command-lifetime cleanup attempted and verified;
- command completed; and
- command failed with any command-lifetime cleanup evidence.

Example-lifetime cleanup occurs later and is reported by cleanup and terminal
run events. A command-finished event does not claim knowledge of cleanup
transactions that are still pending for test teardown.

Transaction lifecycle events are correlated with their owning test attempt and,
when applicable, parent command invocation. They remain available after the
transaction is manually expended or removed from the active teardown registry.

Repeated observations are rate-limited or summarized so a 10-second wait does
not flood the result stream. Terminal evidence includes attempt counts, elapsed
time, configured timeout, last pending reason, stable subject identity, current
focus and viewscreen where relevant, and a bounded receipt summary.

On terminal failure, the runner asks registered diagnostic providers for
bounded evidence appropriate to the command kind. Mounted actions can capture
the selected subject, current component tree, render generation, screen, and
focus. Map and simulation commands can capture stable IDs and scalar state.
Artifact capture failure is reported without masking the command failure.

Sensitive or unbounded values are never published automatically. Definitions
provide explicit diagnostic projection instead of serializing arbitrary
arguments, callbacks, userdata, or component tables.

## Built-in command expectations

The following table defines the intended migration target. It is not a complete
signature specification.

| Commands | Kind | Preflight | Intrinsic verification |
| --- | --- | --- | --- |
| `wait_frames`, `wait_ticks` | Assertion | Scheduler and required game state available | Requested progress count observed |
| `await`, `awaitEvent` | Assertion | Query or event listener can be armed | Truthy query result or exact event receipt observed |
| `isGamePaused`, `getGameSpeed`, `getTick`, `getTime`, `getSaveDirectoryName`, `hasFocus` | Query | Required native state available | Returned observation satisfies its declared type and state contract |
| `setGamePaused`, `setGameSpeed`, `setTurboSpeed` | State setter | Native state is available and valid | Exact requested values are read back |
| `setViewPos` | State setter | Map view and dimensions are available | `getViewPos(origin)` equals the requested position |
| `setUnitPos` | State setter | Unit and source/destination occupancy are safe | Re-resolved unit position and affected occupancy match the receipt |
| `setUnitSpeed` | State setter | Targets and scheduling are available | Recurring ownership is scheduled for the immutable target/configuration snapshot; product progress can use caller verification |
| `mount`, `mountNativeScreen` | Workflow | No current mount and source is valid | Ownership, target, subject source, and render capability are current |
| `unmount` | Workflow | A current mount exists | No current mount, active owned screen, retained subject, or borrowed attachment remains |
| `root`, `get`, `inspect`, `search` | Query | Current mount and selected source remain valid | Stable subject or observation satisfies its source contract |
| `move_pointer`, `hover` | Action | Target and geometry are current and usable | Logical accessors and paired raw coordinates read back at the requested position |
| `input`, `type` | Action | Current input target is valid | Dispatch receipt and required settling/render boundary; product effect uses optional caller verification |
| `mouseInput`, `mouseWheel`, `click` | Action | Pointer, target, button state, and geometry are actionable | Input receipt, pointer consistency, transient-state restoration, and required render boundary; product effect uses optional caller verification |
| `redraw` | Action | Current interaction target supports invalidation | A later completed render generation when waiting is enabled |
| `viewport` | State setter | DwarfSpec owns a resizable host | Applied viewport/layout dimensions and later completed render |
| `capture_view_tree`, `capture_screen` | Query | Requested source or screen is readable | Capture is bounded, plain, retained under the requested name, and structurally valid |
| `exitToMainMenu`, `mountSaveGame` | Workflow | Required native screens and save state are reachable | Exact intermediate and terminal native states |
| `stage_overlay_registration` | Fixture | Source and destination are safe | Exact registration exists; cleanup later verifies registration and unchanged staged artifacts are absent |

The intrinsic input receipt must not claim that DFHack consumed the input unless
the selected ingress provides a reliable consumption signal. If no such signal
exists, the documented guarantee is dispatch, target currency, pointer state,
and settling only.

## Project-defined commands

Project-defined commands move from bare callbacks to validated definitions:

```lua
return {
    commands={
        open_report={
            kind='action',
            default_timeout_ms=5000,
            normalize=function(arguments)
                return arguments
            end,
            preflight=function(context, request)
                -- return command.ready(...) or command.pending(...)
            end,
            execute=function(context, request, ready)
                -- execute once and return command.executed(...)
            end,
            verify=function(context, request, receipt)
                -- optional intrinsic project-command verification
            end,
        },
    },
}
```

Project commands receive the same bounded command context as built-ins. They do
not receive unrestricted host internals.

Bare function callbacks are not adapted. They cannot satisfy the finite command
contract because arbitrary synchronous Lua cannot be interrupted, and an
adapter would preserve the least safe execution path while adding temporary
code and tests. The command-definition format is therefore a deliberate
breaking change for project command modules.

All built-in, repository fixture, and known consumer command modules are
converted as one coordinated migration. Configuration loading fails early with
the source path and command name when it encounters a bare callback. Release
notes and command-authoring documentation provide the mechanical conversion
shape, but the runtime contains only the definition-based path.

## Proposed module ownership

The driver owns the command engine because commands are run-scoped UI and game
workflows:

```text
src/dwarfspec/driver/command/
    context.lua
    deadline.lua
    definition.lua
    diagnostics.lua
    outcomes.lua
    registry.lua
    runner.lua
    workflow.lua
```

- `context.lua` exposes bounded run capabilities.
- `deadline.lua` owns monotonic deadline calculations.
- `definition.lua` validates and freezes definitions.
- `outcomes.lua` constructs ready, pending, fatal, and executed results.
- `registry.lua` merges built-in and project definitions without conflicts.
- `runner.lua` owns the public lifecycle and failure composition.
- `workflow.lua` runs named internal steps under a parent invocation.
- `diagnostics.lua` projects bounded stage-aware evidence.

Existing modules under `driver/commands/` retain domain behavior but export
definitions instead of binding functions directly to `ds`. Simulation, mount,
input, render, and game modules remain capability providers and do not learn
about public API registration.

The host cleanup subsystem owns each test attempt's pending-only LIFO registry
and mutable cleanup execution index. The automation service remains the sole
publisher and owns the authoritative run-scoped event journal. Its test-attempt
finalizer folds the selected attempt's transaction events into the terminal
result projection. Protocol modules own cleanup transaction event types,
disposition enums, and journal/result validation. The controller result
interpreter validates and persists the supplied journal and per-attempt
projections without interpreting pending registry state or cleanup semantics.

The root `dwarfspec.ds` module builds the context and registry, then binds thin
public functions that invoke the runner. It contains no duplicate pointer,
input, game-state, or mount command implementation.

The protocol namespace owns command-kind and failure-stage enums, configuration
validation, and cross-boundary event schemas. The host owns scheduler and clock
capabilities but not command policy. The controller renders the resulting
events without interpreting driver behavior.

## Compatibility strategy

### Public calls

Existing command calls remain source-compatible during migration. Trailing
command options are additive overloads. Existing return values remain unchanged
unless a current return is undocumented or demonstrably inconsistent, in which
case a separate compatibility decision is required.

Subject fluent methods continue returning the subject. Caller verification
does not replace that return.

### Settings

`settings.command.timeout_ms` becomes authoritative. Existing
`settings.wait.timeout_ms` remains a fallback during the compatibility window.
Configuration validation rejects conflicting values only if their precedence
cannot be applied deterministically; otherwise the command setting wins and a
deprecation diagnostic identifies the legacy setting.

### Existing render waits

Wait-by-default behavior is preserved while it moves into intrinsic command
verification. `{wait=false}` remains only where the public command explicitly
offers asynchronous invalidation. It does not disable the command deadline or
other intrinsic checks.

### Existing custom commands

Project command modules must be converted to definition tables before using the
new runner. No legacy runtime adapter is provided. Duplicate-name and
reserved-name protections remain unchanged, and invalid bare callbacks fail
during configuration loading rather than during a test command.

## Validation strategy

The validation strategy separates reusable command-engine proof from repetitive
per-command migration proof. This minimizes churn without weakening the final
claim.

### Command-engine qualification

The runner receives exhaustive deterministic unit coverage once its contract is
introduced. An injected fake monotonic clock and scheduler prove:

- timeout precedence and finite validation;
- one shared deadline across preflight and verification;
- preflight pending, ready, fatal, thrown, cancelled, and timed-out outcomes;
- exactly-once primary execution;
- no execution after preflight expiry;
- intrinsic verification retry and timeout;
- optional caller verification omitted, passed, pending, thrown, and timed out;
- caller verification cannot bypass intrinsic verification;
- receipt preservation after execution and verification failure;
- cleanup prearming, manual expenditure, command-lifetime cleanup, and teardown behavior;
- cleanup state transitions through every terminal disposition, including an
  exactly-once journal event for `unconfirmed`;
- test-attempt attribution across setup, body, and teardown hooks, rejection
  outside an active attempt, and `test.finished` ordering after cleanup-result
  materialization;
- retention of completed, failed, abandoned, and unconfirmed transactions after
  removal from the pending registry;
- exactly-once transaction lifecycle events with stable test-attempt and command
  attribution;
- isolation of transaction IDs, registration order, active registries, and
  result projections across neighboring tests and repeated attempts;
- cursor reads of transaction events during execution and retained-run reads
  after terminalization;
- deterministic terminal result materialization from the authoritative journal
  and equality validation of the persisted projection;
- coordinated protocol-version rejection for incompatible service, event, or
  result schemas;
- combined primary and cleanup failures;
- nested workflow steps sharing the parent deadline;
- target re-resolution across yields;
- bounded and rate-limited diagnostics;
- stable public return values; and
- rejection of bare project command callbacks with source diagnostics.

These tests are not duplicated in every command suite.

### Reusable conformance suites

Table-driven conformance helpers validate common properties for each command
kind. A command registers a small fixture describing expected gate, execution,
verification, timeout, and cleanup observations. The common suite then proves
the lifecycle without custom copies of runner tests.

Command-specific tests focus only on domain behavior: native argument
normalization, target resolution, action receipt, state readback, and diagnostic
projection.

### Risk-based checks during migration

| Change class | Required checks before continuing |
| --- | --- |
| Mechanical definition/binding conversion with unchanged domain behavior | Syntax/static checks, relevant conformance case, and focused command unit suite |
| Command-specific semantic change | Focused unit suite plus the smallest relevant live case when native behavior is involved |
| Runner, deadline, outcome, cleanup, or workflow-engine change | Complete command-engine suite and all directly affected command suites |
| Protocol/configuration schema change | Focused protocol, event-journal, retained-run, result persistence, configuration, host-loading, and declaration checks |
| Completion of a command-family migration | Full unit suite and representative live qualification for that family |
| Final removal of old execution paths and timeout compatibility | Full unit, syntax, declaration, package, framework, and bounded live qualification |

A full live run is not required after a command merely changes registration
shape while preserving tested domain operations. Native live evidence is
repeated when behavior, scheduler boundaries, target resolution, rendering,
cleanup, or protocol behavior changes.

### Representative migration cases

Before broad conversion, the architecture is exercised through deliberately
different commands:

- `search` as a query;
- `click` as a generic action with optional caller verification;
- `setViewPos` as a reversible state setter with exact readback;
- `mountSaveGame` as a multi-step workflow; and
- `stage_overlay_registration` or one managed fixture command as a resource
  transaction with verified cleanup.

The design is reviewed after these representatives. Broad mechanical migration
does not begin until all five fit without command-specific exceptions in the
runner.

### Final qualification

Final qualification proves:

- every declared public command routes through the common runner;
- no duplicate command implementation remains in the root facade;
- every command has a finite effective timeout and explicit preflight;
- every mutator documents its intrinsic verification boundary;
- optional caller verification works for top-level and subject commands;
- primary mutations execute exactly once while verification retries;
- project-defined definitions behave as documented and bare callbacks are rejected during loading;
- command failures reach Busted as test errors with their stage preserved;
- cleanup remains terminally verified after execution and verification
  failures; and
- active and retained service reads plus persisted results expose the complete
  per-test cleanup transaction set with consistent terminal outcomes;
- source, installed, and packaged behavior agree.

Live qualification must finish terminally and include cleanup confirmation. A
bounded command failure followed by confirmed cleanup is valid negative-test
evidence; a silent or externally interrupted run is not.

## Delivery milestones

### Contract and kernel

- Add protocol enums, settings, definition validation, outcome constructors,
  deadline handling, the command context, and the runner.
- Add the per-test cleanup execution index, stable transaction identities,
  authoritative run-journal lifecycle events, and the service-materialized
  per-attempt cleanup result projection.
- Revise the service/event/result protocol together, including cursor reads,
  retained-run inspection, controller interpretation, persistence, formatting,
  and compatibility rejection.
- Add the fake-clock command-engine test harness.
- Extend command events and result rendering.
- Preserve existing built-in public calls while their implementations move to definitions.

### Representative commands

- Migrate the representative query, action, state setter, workflow, and fixture
  commands.
- Add optional trailing command options and declarations for those commands.
- Review receipt boundaries, nested workflow behavior, and diagnostics before
  broad migration.

### Command-family conversion

- Convert read-only queries and waits.
- Convert game and simulation state setters.
- Convert pointer and input actions.
- Convert mount, redraw, viewport, and capture commands.
- Convert save-game workflows and registration fixtures.
- Convert project-defined command loading and repository fixtures to definitions in one coordinated change.

Each family uses its shared conformance suite and one family integration
checkpoint instead of an exhaustive qualification run after every command.

### Consolidation

- Remove direct binding and duplicate implementations from the root facade.
- Remove obsolete mounted-mutation wrappers after all callers use the runner.
- End timeout compatibility: reject `timeout_ms=false` and stop treating
  `settings.wait.timeout_ms` as a command default.
- Update architecture, configuration, command-authoring, test-writing, and API
  documentation.
- Reconcile the managed native-fixture proposal so all proposed fixture
  commands use this runner and receipt model.
- Perform final source, package, framework, and live qualification.

## Relationship to the managed native-fixture proposal

The managed native-fixture proposal remains responsible for the domain semantics
of `spawnItem`, `createStockpile`, `reserveMapTiles`, `spyJobs`, `queryUnits`,
and `runUntil`. This proposal supersedes any conflicting command execution,
timeout placement, cleanup-transaction, retry, migration, or validation-cadence
language in that document. In particular:

- `registerCleanup` returns the manually executable transaction defined here;
- `timeout_ms` belongs to trailing `CommandOptions`, while a frame budget remains
  a logical wait option where applicable;
- mutating primary execution is not retried;
- command definitions replace direct command facades and bare callbacks; and
- the risk-based validation checkpoints here replace per-command package and
  live qualification as unconditional gates between fixture commands.

This proposal becomes authoritative for how those commands execute:

- their preconditions become command preflight gates;
- construction and observation use the shared deadline;
- pending ledger entries are prearmed ownership;
- created IDs and scalar snapshots become receipts;
- creation checks become intrinsic verification;
- caller-supplied product verification remains optional;
- cleanup verification remains mandatory; and
- command events use the shared stage-aware diagnostic schema.

The fixture proposal should not implement a parallel runner, timeout, cleanup,
retry, or validation-cadence model.

## Relationship to the test-runner service design

`test-runner-service-design.md` remains authoritative for project admission,
queue and execution leases, executor quarantine, persistence ownership,
acknowledgement, session retention, cursor reads, and the presentation-neutral
UI boundary.

This proposal revises that design's exact service, event, and result schema
versions, its initial event-type table, and its native test-result projection
only as required for stage-aware command events and per-transaction cleanup
reporting. The coordinated protocol revision must update the service design,
protocol enums and validators, snapshots and transports, retained-run reads,
controller interpretation and formatting, and result persistence together.
Older clients and services continue to fail through protocol negotiation rather
than interpreting the new lifecycle partially.

The service design's retention rule is unchanged: acknowledgement releases the
project admission gate but does not delete the read-only run record, which
remains process-local until the service instance ends. The new cleanup history
uses the existing service journal and result-persistence ownership; it does not
introduce a second publisher, UI-owned state, or per-run result files.

## Documentation requirements

Every public command documents:

- its command kind;
- its effective timeout and override location;
- its preflight requirements;
- whether execution mutates and whether it is one-shot;
- its exact intrinsic verification guarantee;
- what it deliberately cannot verify;
- when caller verification is recommended;
- its ownership and cleanup behavior; and
- its stable return value.

Examples must not imply that render completion proves content correctness.
Generic action examples should normally include a product-level assertion or
verification callback, while also showing that the callback is optional.

Project-command documentation includes a complete definition example, the
cooperative execution limitation, safe diagnostic projection, receipt design,
and the required conversion from callback-only modules.

## Acceptance criteria

The architecture is complete when:

- one runner owns every built-in and project command invocation;
- every command resolves a finite wall-clock deadline;
- every command has an explicit read-only preflight gate;
- every mutating primary operation is exactly once by default;
- intrinsic verification exists wherever the declared framework effect is
  independently observable;
- caller verification is optional, retryable, documented, and unable to weaken
  intrinsic verification;
- nested read-only verification commands inherit the parent deadline and appear
  as child events;
- command timeout errors identify the exact lifecycle stage and last bounded
  observation;
- command-owned mutations prearm cleanup before publication;
- caller cleanup registrations return manually executable transactions, and
  teardown executes every transaction that remains pending;
- caller cleanup registration requires an independent verification operation;
- test-attempt cleanup closes and its result is materialized before
  `test.finished`, while service-owned run cleanup remains separately scoped;
- removing or expending a transaction never removes its lifecycle events from
  the authoritative service journal;
- every registered transaction appears exactly once in its terminal test
  attempt result with `complete`, `failed`, `abandoned`, or `unconfirmed`
  disposition;
- the service event journal and persisted result expose consistent transaction
  identities, ordering, attribution, outcomes, and bounded evidence;
- the journal remains the sole historical source of truth, while live consumers
  fold attempt-tagged events and completed-result consumers may use the
  service-materialized projection at
  `host_report.test_attempts[].cleanup_transactions`;
- cleanup verification remains independent of the expired command deadline;
- built-in command signatures and return values remain compatible through
  documented overloads;
- project command modules use definitions exclusively and bare callbacks fail
  during configuration loading;
- root-facade command implementations and obsolete parallel execution paths are
  removed;
- unlimited command timeouts and the wait-setting fallback are removed;
- the managed native-fixture proposal depends on this architecture instead of
  duplicating it; and
- risk-based migration evidence plus final exhaustive qualification prove the
  complete source and packaged contract.

## Expected outcome

DwarfSpec commands will no longer equate non-throwing dispatch with verified
success. Each command will expose the strongest truthful intrinsic guarantee it
can own, and callers can optionally attach retryable product-specific
verification without building their own timeout loop. Failures will identify
readiness, execution, verification, or cleanup precisely, while one-shot
mutation and verified cleanup preserve deterministic live-test behavior.
