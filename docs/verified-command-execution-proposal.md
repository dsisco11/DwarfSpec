# Verified command execution architecture proposal

## Status

This document proposes a foundational execution model for all public DwarfSpec
commands. It is an architecture proposal, not an implementation checklist and
not a description of shipped behavior.

The proposal adopts Cypress-like command actionability, finite command
deadlines, one-shot mutation by default, proof-gated safe execution retry, and
retryable verification without adopting
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

Preflight and verification may retry within the shared deadline. Every command
definition explicitly selects `ONCE` or `EXPLICIT_RETRY_SAFE` primary execution.
The latter is permitted only when the definition proves that repeated attempts
with one stable operation key are idempotent and cannot duplicate logical
effects. No initial built-in mutating command will opt into execution retry,
but the runner, definition validator, outcomes, diagnostics, and conformance
suite implement and prove the policy from the beginning.

Cleanup registration is effect-driven rather than speculative: a command
registers cleanup only after an execution outcome conclusively identifies an
effect and supplies its receipt, but before any later fallible work, yield,
verification, retry, or publication. A retry cannot begin until cleanup for
every effect reported by the previous attempt completes and verifies.

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
describes a command's name, kind, normalization, preflight, primary-execution
policy, execution, verification, timeout default, and diagnostic policy.

### Command invocation

A command invocation is one run-owned execution of a definition with normalized
arguments, a fixed deadline, command identity, tagged execution-owner identity,
target identity, cleanup checkpoint, and trace.

### Execution owner

Every public command and caller-visible cleanup transaction belongs to exactly
one active execution owner. `EExecutionOwnerScope` contains exactly
`SUITE_EXECUTION` and `TEST_ATTEMPT`. A suite execution is one selected spec file
in one repeat; a test attempt is nested within that suite execution. The tagged
scope and stable owner ID travel together in command events, cleanup events,
result projections, and nested invocation context. Service-owned run cleanup is
outside this enum and keeps its separate run-level protocol.

### Explicit resource-dependency components

`DirectedAcyclicGraph` is the domain-neutral graph mechanism. It owns node and
edge mutation, cycle and self-edge rejection, dependent lookup, and
deterministic topological ordering, but it knows nothing about DwarfSpec owners,
resource claims, cleanup transactions, or lifetimes.

`ResourceDependencyIndex` is the run-scoped DwarfSpec policy layer over one
`DirectedAcyclicGraph` instance and every active DwarfSpec resource claim.
Claims are tagged at the level that owns them:
service-run, suite-execution, test-attempt, or command-invocation. Suite and
test cleanup registries remain isolated, but conflict detection is not isolated:
every claim lookup considers all active levels in the run.

Each claim records a bounded resource kind and stable identity or logical
region, its tagged owner and parent owner chain, its cleanup transaction when
one exists, and any explicit dependency or compatible-sharing relationship.
Its `DirectedAcyclicGraph` stores edges from prerequisite claim to dependent
claim. The index prevents two
scopes from independently claiming an exclusive resource merely because they
use different cleanup registries. It is execution-safety state, not a second
cleanup-history source of truth.

`CleanupPlanner` consumes eligible transactions and the
`ResourceDependencyIndex` to produce dependency-safe reverse-topological
execution order, with owner-local reverse registration order as the tie-breaker
for independent transactions. It does not own claims, transactions, or history.

### Preflight gate

The preflight gate is a read-only predicate that resolves current native or
mounted state and determines whether primary execution is safe to attempt. A
not-ready result is retried. A fatal result or unexpected error terminates the
command immediately.

### Primary execution

Primary execution performs the command's logical mutation or observation.
Mutating definitions use `ONCE` unless they satisfy the explicit retry-safe
contract. Execution returns a private receipt and a public result instead of
requiring verification to infer what was attempted.

### Intrinsic verification

Intrinsic verification checks an effect promised by the DwarfSpec command
contract. Examples include exact state readback, pointer-coordinate readback,
confirmed render completion, current mount ownership, or exact loaded save
identity.

Every definition explicitly selects how its intrinsic evidence is established:

- `PRIMARY_OBSERVATION` for a query or assertion whose validated primary
  observation is the terminal condition;
- `CALLBACK` when an independently observable effect requires a retryable
  intrinsic verification callback; or
- `EXECUTION_RECEIPT` when no stronger generic effect exists and the immutable
  execution receipt is the complete framework-owned evidence.

Omitting a verification callback is therefore never an implicit claim that a
receipt is sufficient.

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

### Retry observation by default; retry mutation only by proof

Preflight and verification are read-only and retryable. Primary mutation is
one-shot by default. A definition may select `EXPLICIT_RETRY_SAFE` only when
repeating the same immutable request and stable operation key is idempotent,
cannot duplicate externally visible logical effects, and preserves cleanup
ownership after every attempt. This prevents delayed UI updates from causing
duplicate clicks, duplicated text, repeated save transitions, or multiple
native resources while still supporting the uncommon operations for which
execution retry is genuinely safe and useful.

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
active suite/test owner and executor recovery contract with its own bounded lifecycle.
An expired command can therefore fail and still restore or remove owned state.

### Register cleanup after a confirmed effect

A command reserves any resource claim needed for exclusivity before mutation,
but it does not register executable cleanup until an execution outcome
conclusively identifies an effect that exists and supplies its immutable cleanup
receipt. The runner registers and links that cleanup synchronously before any
later fallible operation, scheduler yield, verification, retry, or publication
to test code. An execution outcome that produced no effect creates no cleanup
transaction and releases any unused reservation.

Native adapters must therefore report every cleanup-requiring partial effect as
a structured execution, retry, or failure receipt. Throwing after an
unreported mutation is an invalid adapter contract because no cleanup system
can safely infer an identity that the adapter did not return.

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
absolute deadline, cancellation state, root command identity, and tagged suite
or test owner identity. Each nested command or internal workflow step receives its own
run-unique invocation ID and records the immediate `parent_invocation_id`, so
repeated same-named children remain distinguishable in the trace. It cannot
extend or reset the parent timeout. Mutating public commands are rejected from
preflight and verification because those stages must remain read-only. Internal
workflow steps use the same child-event model without becoming independent
public results.

## Command categories

All categories use the common runner, deadline, trace, and failure schema. The
categories specialize retry and verification behavior instead of forcing
meaningless callbacks into every command.

| Kind | Primary behavior | Retry behavior | Verification expectation |
| --- | --- | --- | --- |
| Query | Observe current state | Its read-only primary observation may return pending and retry | Validate and return a stable observation, including a successful `nil` when declared |
| Assertion | Observe a condition | Its read-only primary observation retries until ready | The assertion observation is the terminal condition |
| Action | Perform input or another mutation | Retry preflight and verification; retry execution only under `EXPLICIT_RETRY_SAFE` | Verify framework effects; caller verification is optional |
| State setter | Change reversible state | Retry preflight and readback; retry execution only under `EXPLICIT_RETRY_SAFE` | Exact state readback is intrinsic |
| Workflow | Execute ordered internal steps | Each step occurs once in sequence; its gates may retry and its mutation follows its declared execution policy under the parent deadline | Verify every declared intermediate and terminal state |
| Fixture | Create or reserve owned native state | Retry readiness and readback; retry execution only under `EXPLICIT_RETRY_SAFE` | Verify identity/state after creation and absence/restoration during cleanup |

`ECommandKind` contains exactly `QUERY`, `ASSERTION`, `ACTION`, `STATE_SETTER`,
`WORKFLOW`, and `FIXTURE`. A definition selects exactly one kind. Recurrence,
evidence capture, subject fluency, and cleanup lifetime are orthogonal traits,
not hybrid command kinds.

`EIntrinsicVerificationKind` contains exactly `PRIMARY_OBSERVATION`, `CALLBACK`,
and `EXECUTION_RECEIPT`. Queries and assertions use `PRIMARY_OBSERVATION`;
mutating definitions use `CALLBACK` whenever their declared framework effect is
independently observable and may use `EXECUTION_RECEIPT` only when the receipt
is the strongest truthful generic evidence.

`EExecutionRetryPolicy` contains exactly `ONCE` and `EXPLICIT_RETRY_SAFE`.
Queries and assertions use `ONCE` because their observation loop is already
owned by the query/assertion protocol rather than execution retry. A mutating
definition may use `EXPLICIT_RETRY_SAFE` only with a documented stable operation
key, idempotency guarantee, attempt-receipt policy, and conformance fixture.

Every definition has an explicit preflight function. Commands with no dynamic
readiness requirement use the shared always-ready predicate so the lifecycle
and trace remain uniform.

Every definition has a primary execution function. For queries and assertions,
that function performs the read-only observation and returns `ready`, `pending`,
or `fatal`. A query uses `ready(nil, evidence)` when `nil` is a successful result,
so ordinary misses are not confused with retryable pending state. For actions,
state setters, workflows, and fixtures, primary execution returns `executed`
or, only under `EXPLICIT_RETRY_SAFE`, an explicit retry outcome. Unexpected
errors are fatal and never imply retry.

Read-only means that an operation does not mutate Dwarf Fortress, mounted
product state, or command/cleanup ownership. A query may append bounded,
idempotent diagnostic data owned by its current command invocation. Therefore
`capture_view_tree` and `capture_screen` may retain immutable named artifacts
without becoming mutating product commands, including when nested in
verification. Repeating such a query replaces or deduplicates the same
invocation-owned artifact key; it cannot publish multiple logical artifacts or
register cleanup.

Intrinsic verification is required when the public contract declares an
independently observable effect. A definition may explicitly declare that its
execution receipt is its complete intrinsic evidence when no stronger generic
effect exists. Caller verification remains optional in every case.

## Command definition contract

The following shape is illustrative; exact Lua names may change during
implementation:

```lua
---@class dwarfspec.CommandCleanupPolicy
---@field lifetime dwarfspec.ECleanupLifetime
---@field restore fun(context: dwarfspec.CleanupExecutionContext, request: any, receipt: any)
---@field verify fun(context: dwarfspec.CleanupExecutionContext, request: any, receipt: any): dwarfspec.GateResult
---@field resources? fun(request: any, receipt: any): dwarfspec.ResourceClaim[]

---@class dwarfspec.CommandDefinition
---@field name string
---@field kind dwarfspec.ECommandKind
---@field normalize fun(arguments: table): any
---@field preflight fun(context: dwarfspec.CommandContext, request: any): dwarfspec.GateResult
---@field execute fun(context: dwarfspec.CommandContext, request: any, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field execution_retry_policy dwarfspec.EExecutionRetryPolicy
---@field operation_key? fun(request: any): string
---@field intrinsic_verification dwarfspec.EIntrinsicVerificationKind
---@field verify? fun(context: dwarfspec.CommandContext, request: any, receipt: any): dwarfspec.GateResult
---@field cleanup? dwarfspec.CommandCleanupPolicy
---@field default_timeout_ms? integer
---@field diagnostics? fun(request: any, receipt: any): table
```

The registry validates definitions before run execution begins:

- names are nonempty and do not conflict;
- kinds are supported immutable enum values;
- normalize, preflight, and execute are callable;
- normalize is bounded, synchronous, and non-yielding;
- `execution_retry_policy` is a supported immutable enum value;
- `EXPLICIT_RETRY_SAFE` supplies a stable bounded `operation_key`, documents
  its idempotency and attempt-receipt guarantees, and has a command-specific
  conformance fixture; `ONCE` forbids execution-retry outcomes;
- `operation_key`, when required, is bounded, synchronous, non-yielding, and
  derives the same scalar key from the same normalized request;
- `intrinsic_verification` is a supported immutable enum value compatible with
  the command kind;
- `verify` is required for `CALLBACK`, forbidden for `PRIMARY_OBSERVATION`, and
  absent for `EXECUTION_RECEIPT` unless a separate diagnostic-only callback is
  introduced under a different field;
- `EXECUTION_RECEIPT` definitions explicitly document the receipt guarantee
  validated by their command-specific conformance fixture;
- a definition whose outcomes can report reversible effects supplies one
  immutable cleanup policy with supported lifetime, restore, required verify,
  and bounded resource projection; definitions that cannot produce a cleanup
  effect omit it;
- every executed, retry, or failed effect receipt is valid for the same cleanup
  policy, so the runner can register behavior without asking execution code to
  construct callbacks dynamically;
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
command.retry(reason, attempt_receipt, evidence)
command.failed(message, effect_receipt, evidence)
```

The public result preserves the command's documented return value. The receipt
is available only to intrinsic verification, caller verification,
command-owned cleanup execution and verification, and bounded failure
diagnostics. It is never published directly to the service journal or result.
Returning `false` from a native adapter is not silently interpreted as success;
each definition must explicitly normalize its native acknowledgement into
either a receipt or an execution failure.

`command.retry(...)` is valid only for `EXPLICIT_RETRY_SAFE`. It means that the
attempt completed without a terminal result and that executing again with the
same operation key is safe. The runner stores the immutable attempt receipt in
the private invocation. If that receipt identifies a cleanup-requiring effect,
the runner immediately registers a command-lifetime cleanup transaction for
that execution attempt from the receipt. It then executes and verifies every
transaction registered since that attempt's cleanup checkpoint in
dependency-safe order and removes their resolved resource claims before any
later attempt. A failed or unconfirmed attempt cleanup terminates the command;
the runner never retries on top of an effect it could not prove removed. Only
after successful attempt cleanup does it re-run preflight and volatile-target
validation and possibly attempt execution again under the same absolute command
deadline. Cleanup uses its independent finite deadline, but elapsed cleanup time
still consumes the parent's wall-clock command deadline.

`command.failed(...)` is the structured fatal outcome for an attempt that can
conclusively report a cleanup-requiring partial effect. The runner registers and
retains cleanup from `effect_receipt` before propagating the primary failure.
An omitted effect receipt asserts that the failed attempt produced no effect.
Retry or failure is never inferred from `false`, `nil`, a thrown error, timeout,
or cancellation. A thrown adapter error is valid only when the adapter contract
guarantees that no unreported effect occurred. The retry loop yields
cooperatively between attempts and retains bounded attempt counts and evidence
for terminal diagnostics.

If primary execution throws or returns a declared failure, verification does
not run. Cleanup registered from a structured effect receipt remains owned.
Command-lifetime transactions are expended by the command's finally boundary,
while owner-lifetime transactions remain pending for manual execution or
teardown.

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
2. Normalize and defensively copy logical arguments synchronously. For
   `EXPLICIT_RETRY_SAFE`, derive and freeze the stable operation key as part of
   this bounded normalization boundary.
3. Resolve the finite timeout and create the timed invocation deadline.
4. Publish command-started evidence with sanitized arguments.
5. Mark a cleanup checkpoint and construct the command context.
6. Poll preflight until ready, fatal, cancelled, or timed out.
7. Revalidate volatile target identity immediately before execution. A
   recoverable not-ready result returns to the preflight loop under the same
   deadline; removal, replacement, or another nonrecoverable identity change is
   fatal.
8. Reserve any resource claim required to prevent conflicting mutation; do not
   register executable cleanup before an effect exists.
9. Before each mutating execution attempt, mark an attempt-local cleanup
   checkpoint. For a query or assertion, poll its read-only primary observation until it
   returns ready, fatal, cancelled, or timed out. For a mutating `ONCE`
   definition, execute the primary operation exactly once. For an
   `EXPLICIT_RETRY_SAFE` definition, accept only explicit retry outcomes,
   register cleanup for every reported attempt effect, execute and verify that
   transaction plus every other transaction created since the attempt
   checkpoint before another attempt, re-run preflight and target validation,
   and repeat under the same deadline until executed, fatal, cancelled, or
   timed out.
10. When an executed or failed outcome conclusively reports an effect, register
    and link its cleanup transaction from the immutable receipt before any
    later fallible operation, yield, verification, or publication. Release an
    unused reservation when the outcome proves that no effect occurred.
11. Establish intrinsic evidence according to the definition's explicit
    verification kind. Poll the intrinsic callback for `CALLBACK`; retain the
    validated primary observation for `PRIMARY_OBSERVATION`; or accept the
    immutable receipt for `EXECUTION_RECEIPT`.
12. Poll caller verification when supplied.
13. Execute and verify every still-pending command-lifetime cleanup transaction
    under the cleanup lifecycle, regardless of the primary outcome.
14. Compose primary, verification, and command-lifetime cleanup failures without
    replacing earlier failures.
15. Refresh retained subjects only when the composed outcome remains successful.
16. Publish exactly one terminal command event containing the complete
    command-lifetime cleanup evidence.
17. Return the original public result or propagate the composed failure.

On any failure, the runner records the failing stage and latest evidence. It
does not drain owner-lifetime transactions. Remaining owner transactions stay
registered for manual execution or automatic test/suite teardown. Terminal
command evidence is never published before command-lifetime cleanup can affect
the command's final outcome.

## Command context

The run-scoped command context exposes only bounded capabilities:

- monotonic time and remaining deadline;
- cooperative frame, tick, event, and predicate waits;
- cancellation state;
- current mount and stable-subject resolution;
- command-local cleanup checkpoint and ownership registration;
- run-scoped resource-claim lookup, reservation, dependency, and release;
- render-generation capture and observation;
- safe diagnostic recording;
- internal workflow-step execution; and
- immutable run, execution-owner, and command identity.

It does not expose the host service, controller transport, mutable command
registry, or unrestricted result publisher. Driver modules continue to avoid
imports from `dwarfspec.host`.

## Workflows and internal steps

Commands such as `mountSaveGame()` are workflows rather than single native
actions. A workflow has one public command identity, one deadline, and one
terminal result. It contains named internal steps with their own retryable
preflight and verification callbacks. Each step occurs once in sequence; its
mutation follows its explicit `ONCE` or `EXPLICIT_RETRY_SAFE` execution policy.

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

### Run-scoped resource ownership

`ResourceDependencyIndex` spans service-run, suite-execution, test-attempt,
and command-invocation lifetimes. Each active claim is tagged with its exact
owner, but exclusive-resource checks query the complete run index. A nested
test therefore cannot claim a unit, tile reservation, screen, pointer state, or
other exclusive resource already claimed by its suite merely because its
cleanup registry is different.

Commands may use explicit compatible-sharing or dependency relationships when
a domain contract permits them. Compatibility is never inferred from nesting
or matching coordinates. Consuming or transferring a claim requires an
explicit command contract; otherwise a command may consume only a claim owned
by its exact owner. Cleanup registries and execution indexes remain private to
their individual owners even when the resource index relates their claims.

The shared dependency mechanism is `DirectedAcyclicGraph`, whose nodes are
active claims and whose edges point from prerequisite to dependent. It owns
node insertion/removal, edge insertion/removal, cycle and self-edge rejection,
active-dependent lookup, and deterministic topological ordering.
`ResourceDependencyIndex` owns DwarfSpec-specific lifetime-direction validation
and claim policy. `CleanupPlanner` owns deterministic reverse-topological cleanup
planning. Commands declare domain relationships through
`ResourceDependencyIndex` instead of implementing local dependency lists or
cleanup ordering.

A dependent claim must have a lifetime no longer than every prerequisite.
Command lifetime is nested within its tagged execution owner, a test attempt is
nested within its suite execution, and a suite execution is nested within the
service run. Sibling or otherwise incomparable owners cannot form a dependency
and are rejected by the graph. A separate explicit resource-transfer command
may rehome a claim before a dependency is proposed, but dependency insertion
itself never transfers either the claim or cleanup ownership. An owning cleanup
transaction cannot release a prerequisite while an active dependent remains.

A resource claim may be reserved before mutation for exclusivity, but it is
linked to an executable cleanup transaction only after an effect receipt proves
that cleanup is required. It remains active while cleanup is pending or
running. Successful verified cleanup releases it; a reservation is released
without a cleanup transaction when execution proves that no effect occurred.
Failed or unconfirmed cleanup leaves the claim unresolved and contributes to
executor quarantine until the existing recovery contract proves the resource
clean. Historical cleanup state remains authoritative in the service journal;
the runtime index and graph must not become competing result ledgers.

### Cleanup transaction lifecycle

The cleanup registry owns executable cleanup transactions rather than bare
callbacks. Registration returns a handle with an explicit lifecycle:

```lua
---@class dwarfspec.CleanupTransaction
---Manually expends pending cleanup; raises after recording a cleanup failure.
---The boolean is returned only on the normal success/already-expended path.
---@field execute fun(self: dwarfspec.CleanupTransaction, reason?: string): boolean
---@field isPending fun(self: dwarfspec.CleanupTransaction): boolean
```

A transaction is registered only after its effect exists. It contains a label,
restore operation, required verification operation, immutable cleanup receipt,
stable cleanup evidence, and one of
`pending`, `running`, `complete`, `failed`, `abandoned`, or `unconfirmed`. The
first two states are nonterminal; the remaining four are terminal dispositions.
`abandoned` is restricted to an exceptional internal transaction whose effect
receipt was registered but whose adapter subsequently proves that the native
operation self-rolled back before publication and requires no restoration;
ordinary command execution releases an unused resource reservation without
registering a transaction.
`unconfirmed` means interruption or recoverable execution-host failure prevented
the still-running automation service from establishing a normal cleanup outcome.
Caller registrations have owner lifetime: test-attempt lifetime when created
inside an attempt, or suite-execution lifetime when created in suite-level
setup/teardown. Internal registrations may instead have command lifetime for
transient input flags or similar state. The lifetime enum therefore contains
`OWNER` and `COMMAND`; it does not encode test versus suite separately because
the tagged owner identity supplies that distinction.

Calling `transaction:execute()` manually removes the pending transaction from
the active registry before invoking restore and verification. The handle
then records `complete` or `failed` and is expended. Repeated execution is
idempotent: it reports that no pending work was executed and never invokes the
callbacks again. A manual failure is recorded in authoritative cleanup evidence
and propagates to the active suite or test lifecycle; it is not silently retried
during teardown. On normal return, `true` means the pending transaction was
successfully restored and verified, while `false` means it had already been
expended. Restore or verification failure first records the terminal `failed`
disposition and then raises the composed cleanup failure into the currently
active Busted lifecycle. Manual execution never changes the transaction's
tagged owner: a suite-owned transaction invoked from a nested test remains in
the suite cleanup journal and result projection even though its raised error is
observed by the active test lifecycle.

At test or suite teardown, the cleanup system automatically executes every
transaction that remains pending in dependency-safe reverse-topological order.
Among transactions whose claims are independent, later registration executes
first as the deterministic LIFO tie-breaker. A command's finally boundary uses
the same planner for command-lifetime transactions. One failure does not prevent
later eligible transactions from being attempted. If a dependent remains
active because its cleanup failed or became unconfirmed, the planner does not
execute an unsafe prerequisite cleanup; it records the prerequisite transaction
as `failed` with bounded `dependency_blocked` evidence naming the blocking claim
IDs. Teardown combines all transaction failures with lifecycle probes before
setting `cleanup_confirmed`.

The public cleanup API does not expose cancellation without execution because a
public transaction is registered only with a receipt for an effect that already
exists. Once registered, it must be executed manually or remain pending for
automatic cleanup.

Cleanup receipts are the only supported path for passing restoration inputs to
cleanup callbacks. Registration requires bounded plain receipt data, which the
cleanup engine defensively copies and freezes before adding the transaction to
the registry and journal. Receipts contain stable identities and immutable
scalar baselines needed by restoration and verification, never live native
pointers, callbacks, or cyclic data. The runtime structurally validates the
receipt but does not attempt to infer whether a callback also closes over Lua
values; authoring guidance requires correctness-critical cleanup data to come
from the receipt.

When primary execution produces a stable identity or reversible state change,
the runner registers cleanup from that effect receipt immediately, before any
later fallible operation, scheduler yield, intrinsic verification, retry, or
publication to test code. If a native operation can mutate and then fail, its
adapter returns a structured failure receipt or an operation key that safely
rediscovers the partial effect. An unobservable mutation followed by a thrown
error violates the adapter contract.

State setters capture their inherited baseline before mutation, then register
an owner-lifetime transaction immediately after the effect is conclusively
observed. Fixture commands may reserve an exclusive claim before native
construction, then register cleanup from the returned stable identity before
verification or publication. Command-lifetime transactions are automatically
expended in the command's finally boundary. A command failure does not drain
unrelated or owner-lifetime transactions because callers may catch the failure
and continue the test.

Every cleanup transaction that mutates external state has an independent
verification operation. Cleanup verification is not optional because
`cleanup_confirmed` must remain authoritative. Cleanup uses stable identities
and scalar snapshots, continues after individual failures, and aggregates all
labeled failures.

Each call that expends a transaction receives a new finite cleanup deadline,
independent of the command deadline that caused or preceded cleanup. Timeout
precedence is the registration's `timeout_ms`, then
`settings.cleanup.timeout_ms`, then the framework default of 10,000
milliseconds. Values must be positive finite integers; cleanup cannot be made
unlimited. Manual execution, command-finally execution, and automatic teardown
use the same policy.

Restoration is one-shot and must be nonblocking and bounded. Verification is
read-only and retryable under the remaining cleanup deadline. A truthy return or
no return value after successful assertions passes verification. `false` or
`cleanup.pending(reason, evidence)` yields and retries;
`cleanup.fatal(message, evidence)` fails immediately. A thrown assertion or
error is retained as the latest failed observation and retried until the
deadline, so asynchronously settling native state can still be confirmed.

If restoration throws, verification is still attempted when time remains
because the restore operation may have partially or completely taken effect.
The transaction remains `failed` even if that verification later observes a
clean terminal state, and both outcomes are recorded. Observed restore failure,
verification fatality, or cleanup-deadline expiry produces `failed`;
`unconfirmed` is reserved for interruption that prevents the surviving service
from establishing an outcome. Cleanup callbacks have the same cooperative
limitation as command callbacks and cannot safely be interrupted while executing
synchronous native or Lua code.

Cleanup callbacks have a restricted command boundary. Restore and verification
receive the same immutable cleanup receipt as their only contextual data; they
do not receive mutable transaction state or capture required cleanup identity
through closure variables. The cleanup engine runs each callback inside a
transaction-owned execution context that privately supplies its owner,
deadline, state transitions, and journal attribution and establishes the
ambient command restrictions. A restore callback does not invoke public
commands or register more cleanup. Verification remains read-only: it may
invoke public queries or assertions, but those nested invocations inherit the
cleanup transaction's owner identity, cancellation state, and remaining cleanup
deadline rather than starting a fresh command timeout. Mutating commands and
cleanup registration are fatal contract errors from cleanup verification.
Nested verification commands retain normal child command events while the
transaction remains the owner of the cleanup outcome.

An expired verification deadline does not discard the execution receipt. The
receipt remains available to its registered transaction so partial or
successful mutation can be reversed even when the command never returned to
test code.

### Cleanup history and result reporting

The active pending registry and cleanup history have different responsibilities.
Each cleanup owner scope owns its own active registry and mutable cleanup
execution index. An owner is either a suite execution or a test attempt nested
within that suite execution. The registry contains only transactions that
remain eligible for automatic execution. The execution index retains the
in-process handles, private receipts, and current states required to execute
those transactions; it is never shared between owners. Removing a transaction
from the active registry therefore means only that teardown must not execute it
again. Its already-published lifecycle events remain in the service journal.

Registration assigns a stable transaction ID and registration ordinal before
the transaction can protect or publish mutable state. The transaction ID is
unique within the run, while the registration ordinal is local to the owning
suite execution or test attempt. Its safe event projection contains only
bounded, serialization-safe data:

- owner scope and owner identity, repeat index, stable suite identity, and test
  identity when the owner is a test attempt;
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
owner-scope enum, owning suite-execution or test-attempt ID, repeat index,
stable suite identity, stable test identity when applicable, transaction ID,
and owner-local registration ordinal. Consumers partition the journal by the
tagged owner identity; transactions from suite setup/teardown, different tests,
or repeated suite/test executions never share ownership or result sets.
Service-owned run cleanup remains represented by separate run-level cleanup
events and is never attributed to an arbitrary suite or test.

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
  where a registered effect is proven to have self-rolled back before
  publication without requiring restoration.

If interruption or a recoverable execution-host failure prevents a registered
transaction from reaching one of those normal dispositions while the automation
service remains alive, terminalization records it as `unconfirmed` rather than
silently omitting it and publishes exactly one corresponding
`cleanup.transaction_finished` event. A terminal suite execution or test
attempt retained by that service therefore reports every transaction registered
to that owner with exactly one disposition: `complete`, `failed`, `abandoned`,
or `unconfirmed`. Repeated manual execution does not add a second terminal
event.

Loss of the DFHack process or automation-service instance is outside this
complete-ledger guarantee: its journal is intentionally process-local and cannot
publish new terminal events after destruction. An external persistence owner may
report connection or interruption failure using evidence it already received,
but it must not synthesize missing transaction registrations or dispositions.

### Suite and test-attempt ownership and finalization

One suite execution represents one selected spec file in one repeat. Its
identity becomes active before suite-level setup and remains active through
suite-level teardown and suite cleanup. A test-attempt identity is nested
within that suite execution from before its attempt-local setup hooks through
its body and attempt-local teardown hooks.

All public commands and cleanup registrations are legal in suite-level setup
and teardown. Ownership uses the most specific active scope: work performed
during attempt-local setup, body, or teardown belongs to the test attempt;
work performed in suite-level setup or teardown outside an attempt belongs to
the suite execution. A suite-owned transaction can therefore protect state
shared by all tests in that file and remains pending until manually expended or
suite cleanup. Nested commands inherit the exact owner scope and identity of
their parent. Public commands and cleanup remain invalid when neither a suite
execution nor a test attempt is active. Service-owned run cleanup is a separate
run-level concern and does not appear in either owner projection.

After attempt-local teardown hooks return, registration closes and automatic
cleanup executes every transaction that remains pending. DwarfSpec then
terminalizes interrupted transactions, materializes the attempt's
`cleanup_transactions` result, and only afterward publishes `test.finished`.
The event's behavior status remains distinct from cleanup disposition; failed
or unconfirmed cleanup is reported separately and still contributes to the run
failure and quarantine rules. If interruption prevents the ordinary test
callback from finishing, the emergency finalizer first attempts remaining
test-owned transactions in dependency-safe reverse-topological order with LIFO
tie-breaking whenever the execution host is still usable. Run terminalization
then synthesizes the attempt result and marks only transactions that remain
unresolved `unconfirmed` before `run.finished`.

After suite-level teardown hooks return, suite registration closes and
automatic cleanup executes every remaining suite-owned transaction in
dependency-safe reverse-topological order with LIFO tie-breaking. DwarfSpec
terminalizes unresolved suite transactions, materializes
the suite's cleanup result, and only afterward publishes `suite.finished`.
Suite cleanup failure or an unconfirmed disposition affects the suite and run
outcome and applies the normal executor-quarantine rules, but it is not
retroactively assigned to an arbitrary test attempt. If interruption skips the
ordinary suite finalizer, run terminalization synthesizes the same suite result
before `run.finished`.

Suite finalization is guaranteed even when suite-level setup fails, discovers
no runnable tests, or interruption prevents suite-level teardown from running.
Any suite transaction already registered is executed when possible or
terminalized `unconfirmed`; it is never reassigned to the first or last test.

Before publishing `test.finished`, the service's test-attempt finalizer folds
only that attempt's authoritative transaction events into a
`cleanup_transactions` array ordered by registration ordinal. The service
stores that materialized projection at
`host_report.test_attempts[].cleanup_transactions` in the owning attempt. The
attempt record also carries its parent `suite_execution_id`, repeat index, and
stable test identity. The projection is a convenience for completed-result
consumers, not a second source of truth.

Before publishing `suite.finished`, the suite finalizer performs the same fold
for the suite owner and stores the projection at
`host_report.suite_executions[].cleanup_transactions`, ordered by the suite-local
registration ordinal. Each suite-execution record carries its repeat index,
stable spec-file identity, behavior summary, and cleanup outcome so UI and
persistence consumers can present suite-level transactions without assigning
them to a test.

The controller validates both projections against the complete journal and
persists them unchanged; it does not independently interpret cleanup behavior.
Result-schema validation rejects duplicate IDs, missing terminal dispositions,
inconsistent journal/result outcomes, or a transaction attributed to the wrong
owner scope. The persisted run result retains the complete event journal and
the suite-execution and test-attempt projections, allowing later result-file
readers to inspect the same history.

The service publishes these events through its existing append-only journal and
cursor APIs. Live consumers can therefore observe registration and state
changes by folding the selected suite or attempt owner's events without polling
private cleanup objects. Completed-result consumers use the
service-materialized projection.
Retained-run inspection continues to expose the complete authoritative history
for the lifetime of the service instance.
Acknowledgement releases the outstanding-run admission gate but does not erase
the read-only session record.
Result persistence derives from the same terminal service snapshot and journal;
there is no separate UI-only cleanup channel or second source of truth.

The new suite lifecycle events, transaction events, and owner-scoped result
projections require a coordinated protocol revision. The implementation bumps
the service/event/result schema versions together, updates validators and
controller interpretation, and rejects mixed clients and services through the
existing protocol negotiation boundary.
It does not write transaction events into an older schema whose consumers cannot
validate their lifecycle.

Successful cleanup remains absent from high-level warning and status surfaces.
That presentation rule does not hide the history: an on-demand cleanup trace,
suite-execution inspector, or test-attempt inspector may enumerate successful,
failed, abandoned, and unconfirmed transactions. Failures and unconfirmed
transactions remain prominent without requiring the UI to calculate cleanup
precedence itself.

## Diagnostics and command events

The command observer expands from start/finish reporting to stage-aware events.
The exact protocol may aggregate repeated pending observations, but it must be
able to represent:

- command started;
- preflight pending, passed, fatal, or timed out;
- execution attempt started, explicitly requested retry, completed, failed, or
  exceeded its deadline, including operation-key and attempt correlation;
- intrinsic verification pending, passed, failed, or timed out;
- caller verification pending, passed, failed, or timed out;
- command-lifetime cleanup attempted and verified;
- command completed; and
- command failed with any command-lifetime cleanup evidence.

Every command and workflow-step event carries its run-unique `invocation_id`,
optional `parent_invocation_id`, `root_invocation_id`, owner-scope enum, owning
suite-execution or test-attempt ID, repeat index, and stable suite/test identity
as applicable. Top-level commands have no parent and use their own invocation ID
as the root ID. Child queries and workflow steps use distinct invocation IDs
even when their command names and normalized arguments are identical, and they
inherit the parent's owner scope exactly.

Owner-lifetime cleanup occurs later and is reported by cleanup and terminal
run events. A command-finished event does not claim knowledge of cleanup
transactions that are still pending for their test or suite teardown.

Transaction lifecycle events are correlated with their tagged suite-execution
or test-attempt owner and, when applicable, parent command invocation. They
remain available after the transaction is manually expended or removed from
the active teardown registry.

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
            execution_retry_policy='once',
            intrinsic_verification='callback',
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
                -- required by the CALLBACK intrinsic-verification policy
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
- `outcomes.lua` constructs ready, pending, fatal, executed, and explicit
  execution-retry results.
- `registry.lua` merges built-in and project definitions without conflicts.
- `runner.lua` owns the public lifecycle and failure composition.
- `workflow.lua` runs named internal steps under a parent invocation.
- `diagnostics.lua` projects bounded stage-aware evidence.

Existing modules under `driver/commands/` retain domain behavior but export
definitions instead of binding functions directly to `ds`. Simulation, mount,
input, render, and game modules remain capability providers and do not learn
about public API registration.

The host cleanup subsystem owns separate pending-only owner registries with
stable registration ordinals and mutable cleanup execution indexes for suite
executions and their nested test attempts. A run-scoped
`ResourceDependencyIndex` relates active claims across
service-run, suite-execution, test-attempt, and command-invocation levels while
preserving those owner-local cleanup registries. Its
`DirectedAcyclicGraph` owns generic dependency structure and ordering,
`ResourceDependencyIndex` owns resource and lifetime policy, and
`CleanupPlanner` produces transaction execution plans for every command family;
individual adapters do not duplicate any of that logic.
The automation service remains the sole publisher and owns the authoritative
run-scoped event journal. Its
suite and test-attempt finalizers
fold the selected owner's transaction events into terminal result projections.
Protocol modules own execution-owner scopes, transaction event types, disposition
and lifetime enums, and journal/result validation. The controller result interpreter
validates and persists the supplied journal and owner-scoped projections
without interpreting pending registry state or cleanup semantics.

The root `dwarfspec.ds` module builds the context and registry, then binds thin
public functions that invoke the runner. It contains no duplicate pointer,
input, game-state, or mount command implementation.

The protocol namespace owns command-kind, execution-retry-policy,
intrinsic-verification-kind, execution-owner-scope, and failure-stage enums,
configuration validation, and cross-boundary event schemas.
The host owns scheduler and clock capabilities but not command policy. The
controller renders the resulting events without interpreting driver behavior.

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
- required intrinsic-verification policy selection, callback/policy agreement,
  and rejection of an implicit receipt-only definition;
- one shared deadline across preflight and verification;
- preflight pending, ready, fatal, thrown, cancelled, and timed-out outcomes;
- `ONCE` primary execution and rejection of every execution-retry outcome;
- `EXPLICIT_RETRY_SAFE` definition validation, stable operation keys,
  cooperative yielding, re-preflight and target revalidation between attempts,
  private attempt-receipt retention, verified cleanup of every reported attempt
  effect before another attempt, cleanup-failure termination, eventual success,
  fatality, cancellation, and shared-deadline expiry;
- proof that `false`, `nil`, and thrown execution errors never trigger implicit
  execution retry;
- no execution after preflight expiry;
- intrinsic verification retry and timeout;
- optional caller verification omitted, passed, pending, thrown, and timed out;
- caller verification cannot bypass intrinsic verification;
- receipt preservation after execution and verification failure;
- cleanup registration immediately after a conclusive effect receipt, manual
  expenditure, command-lifetime cleanup, and teardown behavior;
- cleanup receipt validation, defensive freezing, identical callback delivery,
  runtime enforcement of required receipt data without attempting to inspect
  callback closure semantics, and exceptional self-rollback abandonment;
- cleanup state transitions through every terminal disposition, including an
  exactly-once journal event for `unconfirmed`;
- resource-claim reservation before mutation, cross-level exclusive-conflict
  detection, explicit compatible sharing and dependency relationships, and
  reusable DAG cycle/lifetime validation, reverse-topological cleanup with LIFO
  tie-breaking, rejection of prerequisite-claim release while a dependent claim
  remains active, deterministic `dependency_blocked` failure materialization,
  and verified release or quarantine retention;
- one-shot restoration and retryable cleanup verification under an independent
  finite cleanup deadline, including restoration errors followed by attempted
  verification and cleanup timeout reporting;
- suite-execution attribution across suite setup and teardown, test-attempt
  attribution across attempt setup, body, and teardown, most-specific-scope
  selection, rejection outside both active scopes, and `test.finished` and
  `suite.finished` ordering after their cleanup-result materialization;
- manual execution of a suite-owned transaction from a nested test without
  ownership transfer, plus suite terminalization after setup failure, skipped
  teardown, or zero runnable tests, and emergency test cleanup before
  interruption terminalization;
- retention of completed, failed, abandoned, and unconfirmed transactions after
  removal from the pending registry;
- exactly-once transaction lifecycle events with stable suite/test owner and
  command attribution;
- isolation of transaction IDs, registration order, active registries, and
  result projections across suite executions, neighboring tests, and repeats;
- cursor reads of transaction events during execution and retained-run reads
  after terminalization;
- deterministic terminal result materialization from the authoritative journal
  and equality validation of the persisted projection;
- coordinated protocol-version rejection for incompatible service, event, or
  result schemas;
- combined primary and cleanup failures;
- rejection of public mutations and cleanup registration from cleanup
  callbacks, plus read-only cleanup-verification commands inheriting the
  transaction deadline and owner;
- nested workflow steps sharing the parent deadline;
- unique nested invocation identities and exact parent-child event correlation;
- target re-resolution across yields;
- bounded and rate-limited diagnostics;
- stable public return values; and
- rejection of bare project command callbacks with source diagnostics.

These tests are not duplicated in every command suite.

### Reusable conformance suites

Table-driven conformance helpers validate common properties for each command
kind and execution-retry policy. A command registers a small fixture describing
expected gate, execution, verification, timeout, retry-safety proof, and cleanup
observations. The common suite then proves the lifecycle without custom copies
of runner tests. A synthetic retry-safe definition exercises the complete
policy even though no initial built-in command opts into it.

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
- `ONCE` mutations execute exactly once, and retry-safe mutations retry only
  after explicit outcomes under their stable operation key and verified cleanup
  of every effect from the previous attempt;
- commands and cleanup registered in suite-level setup/teardown are attributed,
  finalized, reported, and persisted under their suite execution;
- project-defined definitions behave as documented and bare callbacks are rejected during loading;
- command failures reach Busted as test errors with their stage preserved;
- cleanup remains terminally verified after execution and verification
  failures; and
- active and retained service reads plus persisted results expose the complete
  per-suite and per-test cleanup transaction sets with consistent terminal
  outcomes;
- source, installed, and packaged behavior agree.

Live qualification must finish terminally and include cleanup confirmation. A
bounded command failure followed by confirmed cleanup is valid negative-test
evidence; a silent or externally interrupted run is not.

## Delivery milestones

### Contract and kernel

- Add protocol enums, settings, definition validation, outcome constructors,
  execution-retry policy and outcomes, deadline handling, the command context,
  and the runner.
- Add suite-execution and test-attempt cleanup indexes, stable transaction
  identities, authoritative run-journal lifecycle events, and the
  service-materialized owner-scoped cleanup result projections.
- Add the run-scoped `ResourceDependencyIndex`, its
  `DirectedAcyclicGraph`, cross-level conflict and lifetime policy,
  `CleanupPlanner`, and verified claim release.
- Revise the service/event/result protocol together, including cursor reads,
  suite lifecycle events, retained-run inspection, controller interpretation,
  persistence, formatting, and compatibility rejection.
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
- initial managed fixture mutations use `ONCE`; any later retry-safe fixture
  must satisfy the shared explicit policy rather than inventing local retry;
- command definitions replace direct command facades and bare callbacks; and
- the risk-based validation checkpoints here replace per-command package and
  live qualification as unconditional gates between fixture commands.

This proposal becomes authoritative for how those commands execute:

- their preconditions become command preflight gates;
- construction and observation use the shared deadline;
- cleanup transactions are registered immediately from conclusive effect
  receipts before verification or publication;
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
only as required for stage-aware command events, suite-execution lifecycle, and
owner-scoped per-transaction cleanup reporting. The coordinated protocol revision must update the service design,
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
- whether execution mutates, its execution-retry policy, and any retry-safety
  proof and stable operation key;
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
the required conversion from callback-only modules, and a complete
`EXPLICIT_RETRY_SAFE` example showing its operation key, idempotency proof,
explicit retry outcome, attempt receipt, verified prior-attempt cleanup, and
cleanup ownership.

## Acceptance criteria

The architecture is complete when:

- one runner owns every built-in and project command invocation;
- every command resolves a finite wall-clock deadline;
- every command has an explicit read-only preflight gate;
- every mutating primary operation is exactly once by default;
- `EXPLICIT_RETRY_SAFE` is fully implemented, retries only explicit outcomes
  under one stable operation key and deadline, preserves attempt receipts,
  executes and verifies cleanup for every prior attempt effect before retrying,
  and is rejected without its idempotency proof;
- intrinsic verification exists wherever the declared framework effect is
  independently observable;
- caller verification is optional, retryable, documented, and unable to weaken
  intrinsic verification;
- nested read-only verification commands inherit the parent deadline and appear
  as child events with unique invocation and parent identities;
- command timeout errors identify the exact lifecycle stage and last bounded
  observation;
- command-owned effects register cleanup synchronously from their receipts
  before later fallible work, yielding, verification, retry, or publication;
- resource claims are tracked across service-run, suite-execution,
  test-attempt, and command-invocation levels, with exclusive conflicts checked
  across the complete run rather than only within one cleanup registry;
- one `DirectedAcyclicGraph` rejects cycles, `ResourceDependencyIndex` rejects
  invalid lifetime direction, and `CleanupPlanner` plans
  dependent-before-prerequisite cleanup and uses LIFO only to
  order independent transactions, and never transfers ownership implicitly;
- caller cleanup registrations return manually executable transactions, and
  teardown executes every transaction that remains pending;
- cleanup callbacks receive a required immutable transaction receipt, and the
  runtime validates that receipt without claiming it can enforce callback
  closure semantics;
- caller cleanup registration requires an independent verification operation;
- cleanup restoration is one-shot, cleanup verification is retryable, and every
  cleanup execution has a finite deadline independent of its owning command;
- command-lifetime and owner-lifetime automatic cleanup execute in
  dependency-safe reverse-topological order, with reverse registration order
  used only for independent transactions within their respective scope;
- test-attempt cleanup closes and its result is materialized before
  `test.finished`; suite-execution cleanup closes and its result is materialized
  before `suite.finished`; service-owned run cleanup remains separately scoped;
- removing or expending a transaction never removes its lifecycle events from
  the authoritative service journal;
- every registered transaction owned by a terminal suite execution or test
  attempt retained by a surviving service appears exactly once in that owner's
  result with `complete`, `failed`, `abandoned`, or `unconfirmed` disposition;
- the service event journal and persisted result expose consistent transaction
  identities, ordering, attribution, outcomes, and bounded evidence;
- the journal remains the sole historical source of truth, while live consumers
  fold owner-tagged events and completed-result consumers may use the
  service-materialized projections at
  `host_report.suite_executions[].cleanup_transactions` and
  `host_report.test_attempts[].cleanup_transactions`;
- cleanup verification remains independent of the expired command deadline;
- cleanup restore callbacks cannot recursively invoke public commands, while
  read-only commands used by cleanup verification inherit the transaction's
  owner and remaining cleanup deadline;
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
readiness, execution, verification, or cleanup precisely. One-shot mutation by
default, proof-gated safe retry, and verified cleanup preserve
deterministic live-test behavior.
