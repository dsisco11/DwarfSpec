# Verified command execution architecture proposal

## Status

This document proposes a foundational execution model for all public DwarfSpec
commands. It is an architecture proposal, not an implementation checklist and
not a description of shipped behavior.

The domain-neutral `DirectedAcyclicGraph` is specified by the prerequisite
[directed acyclic graph utility proposal](directed-acyclic-graph-proposal.md).
This proposal owns only its resource-policy and cleanup-planning consumers.

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

Automatic command cleanup registration and resource ownership are effect-driven
rather than speculative. Before mutation, the runner validates an inert claim
plan without adding active claims. Only after an execution outcome conclusively
identifies an effect does it atomically register the cleanup transaction and its
active claims, before any later fallible work, yield, verification, retry, or
publication. A retry cannot begin until cleanup for every effect reported by the
previous attempt completes and verifies. The public `registerCleanup()` action
is the explicit post-effect lifecycle operation that creates the same
transaction-and-claim unit without recursively registering cleanup for
registration. There is no public pre-effect resource-claim reservation handle;
domain commands such as `reserveMapTiles()` create a real logical effect and
receive their active claims only with that effect's cleanup transaction.

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
policy, pre-execution resource-claim planning, execution, verification, timeout
default, and diagnostic policy.

### Command invocation

A command invocation is one run-owned execution of a definition with normalized
arguments, a fixed deadline, command identity, tagged execution-owner identity,
target identity, cleanup checkpoint, and trace.

### Execution owner

Every public command and caller-visible cleanup transaction belongs to exactly
one active execution owner. `EExecutionOwnerScope` contains exactly
`SERVICE_RUN`, `SUITE_EXECUTION`, and `TEST_ATTEMPT`. A suite execution is one
selected spec file in one repeat; a test attempt is nested within that suite
execution. `SERVICE_RUN` command ownership is reserved for read-only query or
assertion children invoked by service-owned cleanup verification; it cannot be
selected by an ordinary top-level public invocation or cleanup registration.
The tagged scope and stable owner ID travel together in command events, cleanup
events, result projections, and nested invocation context.

All effect-backed cleanup uses one transaction abstraction.
`ECleanupOwnerScope` contains `SERVICE_RUN`, `SUITE_EXECUTION`, and
`TEST_ATTEMPT`. Public registration selects the active suite or test owner;
internal service effects select `SERVICE_RUN`. Every scope allocates the same
run-unique transaction IDs and participates in the same resource-dependency and
cleanup-planning contracts, while journal and result projections remain
partitioned by cleanup owner scope.

### Explicit resource-dependency components

`DirectedAcyclicGraph` is the domain-neutral graph mechanism defined by the
prerequisite proposal. This proposal does not extend its API with DwarfSpec
policy.

`ResourceDependencyIndex` is the run-scoped DwarfSpec policy layer over one
`DirectedAcyclicGraph` instance and every active DwarfSpec resource claim.
Claims are tagged at the level that owns them:
service-run, suite-execution, test-attempt, or command-invocation. Suite and
test cleanup registries remain isolated, but conflict detection is not isolated:
every claim lookup considers all active levels in the run.

Each claim records a bounded resource kind and stable identity or logical
region, its tagged owner and parent owner chain, its cleanup transaction, and
any explicit dependency or compatible-sharing relationship.
Its `DirectedAcyclicGraph` stores edges from prerequisite claim to dependent
claim. The index prevents two
scopes from independently claiming an exclusive resource merely because they
use different cleanup registries. It is execution-safety state, not a second
cleanup-history source of truth.

`ResourceClaimPlanEntry` is an inert pre-execution declaration returned by
`claims()`. Every entry has a nonempty `claim_key` unique within its invocation,
plus its resource kind, exclusivity/sharing policy, relationship selectors, and
either an exact existing-resource identity or a provisional creation identity.
A local relationship selector names another `claim_key` in the same plan. A
relationship to an already active claim instead uses a
`ResourceClaimReference`; local keys and existing-claim references are distinct
fields and are never inferred from one another. Validation simulates the plan
against `ResourceDependencyIndex`, but it allocates no claim ID, changes no
index state, and creates no cleanup transaction.

`ResourceClaimReference` is an immutable, bounded, opaque value containing a
run-unique claim ID and the minimum owner/resource correlation needed for
validation. It grants no index access. A caller-visible cleanup transaction can
return references for the claims it owns. A runner-managed resource-producing
command exposes a reference in its stable public result only when its documented
domain contract permits downstream dependency or compatible-sharing
relationships. `ResourceDependencyIndex` rejects forged, stale, foreign-run,
or policy-incompatible references. Because references exist only for active
claims, an inert plan can never be referenced as a prerequisite or sharing peer.

`ResourceClaimBinding` is the post-execution projection returned by cleanup
policy `resources(effect_receipt)`. It names a planned `claim_key` and, for a
provisional creation entry, supplies the concrete stable resource identity
established by the effect receipt. It cannot introduce a relationship or claim
that was absent from the validated plan. This explicit mapping lets an outcome
activate any subset of a multi-entry plan without relying on array position or
inferred identity; unused plan entries are simply discarded.

`ResourceClaimRegistration` is the post-effect descriptor accepted from a
downstream caller by `registerCleanup()`. It contains a nonempty caller-local
`claim_key`, exact stable resource identity or logical region, resource kind,
exclusivity/sharing policy, and explicit local or active-reference
relationships. It cannot contain a provisional identity because the caller's
effect already exists. The registration service validates the complete set and
creates its claims atomically with the cleanup transaction.

Every active resource claim represents a confirmed cleanup-requiring effect and
belongs to exactly one registered cleanup transaction. An inert claim plan is
not ownership state and never appears in the resource index, cleanup journal, or
result projections.

`CleanupPlanner` consumes eligible transactions and the
`ResourceDependencyIndex` to produce dependency-safe reverse-topological
execution order, with owner-local reverse registration order as the tie-breaker
for independent transactions. It does not own claims, transactions, or history.
For each plan it derives a `CleanupTransactionDependencyGraph`: a temporary
`DirectedAcyclicGraph` whose nodes are transaction IDs and whose edges are the
claim-level prerequisite relationships projected between their owning
transactions. Claim edges within one transaction collapse away. Before command
mutation, `CleanupPlanner` simulates the inert plan as one prospective
transaction node and rejects a claim- or transaction-level cycle without
changing runtime ownership. Post-effect activation revalidates the committed
subset and replaces that simulation node with the newly allocated transaction
ID in one service mutation. The simulation node is an internal graph-local
placeholder, not a transaction: it has no transaction ID, registry entry,
journal event, result record, or externally referenceable claim.

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

A command validates an inert resource-claim plan before mutation, but it does
not create active claims or register executable cleanup until an execution
outcome conclusively identifies an effect that exists and supplies its immutable
cleanup receipt. The runner registers the cleanup transaction and activates its
bound claims atomically before any later fallible operation, scheduler yield,
verification, retry, or publication to test code. An execution outcome that
produced no effect creates neither a cleanup transaction nor active claims.

Native adapters must therefore report every cleanup-requiring partial effect as
a structured execution, retry, or failure receipt. Throwing after an
unreported mutation is an invalid adapter contract because no cleanup system
can safely infer an identity that the adapter did not return.

### Re-resolve live targets

Preflight and verification re-resolve subjects and native identities from their
stable descriptors. They do not retain an assumed-live widget or DF userdata
across scheduler yields. The final successful preflight observation is checked
again immediately before primary execution when a target can become stale.

### Primary execution does not call public commands internally

Composite behavior uses internal operations or workflow steps. This avoids
nested independent deadlines, duplicate command events, repeated cleanup
registration, and misleading success records. For example, `click()` may use
the pointer-placement operation internally, but it does not invoke a second
public `move_pointer()` command. Read-only public queries and assertions are the
only exception, and only from preflight or verification where their nested
lifecycle is explicitly defined below; primary execution never invokes them.

### Nested read-only commands inherit their parent invocation

A query or assertion invoked by preflight or verification inherits the parent's
absolute deadline, cancellation state, root command identity, tagged suite or
test owner identity, and current read-only stage. Each nested command or
internal workflow step receives its own
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

Every non-workflow definition has a primary execution function. For queries and
assertions, that function performs the read-only observation and returns
`ready`, `pending`, or `fatal`. A query uses `ready(nil, evidence)` when `nil` is
a successful result, so ordinary misses are not confused with retryable pending
state. For actions, state setters, and fixtures, primary execution returns
`executed` or, only under `EXPLICIT_RETRY_SAFE`, an explicit retry outcome. A
workflow instead supplies the validated named-step definition executed by the
workflow runner. Unexpected errors are fatal and never imply retry.

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
---@field restore fun(context: dwarfspec.CleanupExecutionContext, receipt: any)
---@field verify fun(context: dwarfspec.CleanupExecutionContext, receipt: any): boolean|dwarfspec.GateResult|nil
---@field resources? fun(receipt: any): dwarfspec.ResourceClaimBinding[]

---@class dwarfspec.CommandDefinition
---@field name string
---@field kind dwarfspec.ECommandKind
---@field normalize fun(arguments: table): any
---@field preflight fun(context: dwarfspec.CommandReadContext, request: any): dwarfspec.GateResult
---@field claims? fun(context: dwarfspec.CommandReadContext, request: any, ready: any): dwarfspec.ResourceClaimPlanEntry[]
---@field execute? fun(context: dwarfspec.CommandExecutionContext, request: any, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field workflow? dwarfspec.WorkflowDefinition
---@field execution_retry_policy dwarfspec.EExecutionRetryPolicy
---@field operation_key? fun(request: any): string
---@field intrinsic_verification dwarfspec.EIntrinsicVerificationKind
---@field verify? fun(context: dwarfspec.CommandReadContext, request: any, receipt: any): dwarfspec.IntrinsicVerificationResult
---@field cleanup? dwarfspec.CommandCleanupPolicy
---@field default_timeout_ms? integer
---@field diagnostics? fun(request: any, receipt: any): table
```

The registry validates definitions before run execution begins:

- names are nonempty and do not conflict;
- kinds are supported immutable enum values;
- normalize and preflight are callable;
- a `WORKFLOW` definition supplies `workflow`, omits `execute`, and uses the
  successful completion of its validated steps and result projector as its
  primary execution; it selects `ONCE` and `EXECUTION_RECEIPT` at the containing
  level and omits containing-level `claims`, `operation_key`, `verify`, and
  `cleanup` because its steps own those policies; every other kind supplies
  `execute` and omits `workflow`;
- `claims`, when present, is callable and is the only definition hook that may
  declare an inert pre-execution resource-claim plan;
- `execution_retry_policy` is a supported immutable enum value;
- `EXPLICIT_RETRY_SAFE` supplies a callable `operation_key`, while `ONCE` omits
  it;
- `intrinsic_verification` is a supported immutable enum value compatible with
  the command kind;
- `verify` is required for `CALLBACK`, forbidden for `PRIMARY_OBSERVATION`, and
  absent for `EXECUTION_RECEIPT` unless a separate diagnostic-only callback is
  introduced under a different field;
- a definition whose outcomes can report reversible effects supplies one
  immutable cleanup policy with supported lifetime and callable restore,
  required verify, and optional resource projection; definitions that cannot
  produce a cleanup effect omit it;
- verify and diagnostics are callable when present;
- timeout defaults are positive finite integers;
- definitions cannot replace reserved built-in commands.

Definition tables are copied or frozen at registration so a consumer cannot
change command behavior while a run is active.

This registry pass is structural validation. It cannot prove semantic
idempotency, bounded execution, absence of yielding, read-only behavior, inspect
documentation, or discover a test fixture. Stage-specific contexts enforce the
available capabilities, while conformance tests prove callback behavior that
function shape cannot establish. Qualification separately requires every
normalizer and `claims` projector to be bounded, synchronous, and non-yielding,
every preflight, claims, and verification callback to remain read-only, and
every `EXPLICIT_RETRY_SAFE` definition to document its idempotency and
attempt/effect-receipt guarantees and pass a command-specific conformance
fixture. Operation-key conformance proves stable bounded scalar derivation from
the same normalized request. Cleanup-resource conformance proves that the
projection accepts only the effect receipt and emits valid bindings to
the pre-execution plan. Diagnostic conformance proves bounded plain output.
Likewise, each `EXECUTION_RECEIPT` definition documents and tests the receipt
guarantee that the registry can only select structurally.
At invocation time, the runner separately validates every returned outcome
against its frozen definition: `ONCE` cannot return retry, a definition without
a cleanup policy cannot return an effect receipt, each effect receipt must be
valid for the one immutable cleanup policy, and cleanup resources must match the
claim plan validated before that attempt. Execution code never constructs cleanup
callbacks dynamically.

## Gate result protocol

Preflight returns one of three explicit outcomes:

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

Intrinsic verification returns the same ready, pending, and fatal outcomes and
may additionally return:

```lua
command.effect_absent(message, evidence)
```

`effect_absent` is valid only when the current execution already registered a
pending cleanup transaction from an explicit effect receipt. It means an
independent observation using the receipt's stable identity proves that the
effect self-rolled back before command-result publication. The bounded evidence
must identify the observation and is the abandonment proof. The runner asks the
private cleanup-registration service to abandon that exact transaction and then
fails the command's intrinsic-verification stage because its intended effect did
not persist. Preflight, caller verification, and cleanup verification cannot
return this outcome.

## Primary execution result

Primary execution returns a private structured result:

```lua
command.executed(public_result, receipt, effect_receipt)
command.retry(reason, attempt_receipt, effect_receipt, evidence)
command.failed(message, effect_receipt, evidence)
```

The public result preserves the command's documented return value. `receipt` is
the private primary-operation evidence used by intrinsic verification, caller
verification, and bounded failure diagnostics. `effect_receipt` is the separate
optional immutable receipt that conclusively identifies a cleanup-requiring
effect. Either may contain the same scalar data, but the definition must pass
the effect receipt explicitly; the runner never infers cleanup merely because a
verification receipt exists. Neither receipt is published directly to the
service journal or result.
Returning `false` from a native adapter is not silently interpreted as success;
each definition must explicitly normalize its native acknowledgement into
either a receipt or an execution failure.

For every outcome, an omitted `effect_receipt` explicitly asserts that the
attempt produced no cleanup-requiring effect. A mutating definition with a
cleanup policy may return either form; a definition without a cleanup policy
must not return an effect receipt.

`command.retry(...)` is valid only for `EXPLICIT_RETRY_SAFE`. It means that the
attempt completed without a terminal result and that executing again with the
same operation key is safe. The runner stores the immutable attempt receipt in
the private invocation. If the explicit `effect_receipt` identifies a
cleanup-requiring effect, the runner immediately registers a cleanup transaction
from it. The cleanup policy's normal lifetime does not apply to this transaction:
every retry-attempt effect is forcibly command-lifetime so another attempt can
never execute on top of it. The runner then executes and verifies every
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
Cleanup registered for terminal `executed` or `failed` effects uses the cleanup
policy's declared lifetime. This is distinct from the forced command lifetime
of a retry-attempt effect.
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
The same inheritance and child-event rules apply when a definition's preflight
calls a read-only public query or assertion; the child remains attributed to the
parent's preflight stage and cannot reset its polling budget.
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
8. Invoke the definition's read-only `claims(context, request, ready)` hook when
    present. Validate and freeze its inert plan against
    `ResourceDependencyIndex` without changing index state. Reject any conflict,
    invalid dependency, lifetime direction, simulated claim-graph cycle, or
    simulated transaction-graph cycle before mutation; do not create an
    active claim or executable cleanup before an effect exists.
9. Before each mutating execution attempt, mark an attempt-local cleanup
    checkpoint. For a query or assertion, poll its read-only primary observation until it
    returns ready, fatal, cancelled, or timed out. For a mutating `ONCE`
    definition, execute the primary operation exactly once. For an
   `EXPLICIT_RETRY_SAFE` definition, accept only explicit retry outcomes,
   register cleanup for every reported attempt effect, execute and verify that
   transaction plus every other transaction created since the attempt
   checkpoint before another attempt, re-run preflight, target validation, and
    `claims` projection/validation, and repeat under the same deadline until
    executed, fatal, cancelled, or timed out. For a `WORKFLOW`, run its validated
    named steps through these same per-kind rules and derive the containing
    execution receipt and public result from the completed immutable workflow
    state.
10. When an executed or failed outcome conclusively reports an effect, register
    its cleanup transaction and activate its bound claims together from the
    explicit immutable effect receipt before any later fallible operation,
    yield, verification, or publication. Every cleanup resource binding must
    name a `claim_key` in the plan validated by step 8 and cannot add a new
    relationship. When the outcome proves that no effect occurred, discard the
    inert plan without changing runtime ownership.
11. Establish intrinsic evidence according to the definition's explicit
    verification kind. Poll the intrinsic callback for `CALLBACK`; retain the
    validated primary observation for `PRIMARY_OBSERVATION`; or accept the
    immutable receipt for `EXECUTION_RECEIPT`. A valid `effect_absent` outcome
    atomically abandons the already-registered internal transaction, releases
    its claims, and fails intrinsic verification.
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

Claim-plan disposal is runner-owned and applies on every no-effect exit path.
Because validation created no active claim, pre-execution cancellation, timeout,
structured no-effect, and a thrown adapter error whose contract guarantees no
effect require no resource-index unwind. If effect absence cannot be
established, the adapter contract has failed; the runner retains the available
effect evidence, records unresolved resource ownership, and invokes executor
quarantine rather than pretending that an inert plan protected unknown state.

## Command context boundaries

Callbacks never receive the runner's mutable invocation state. A
`CommandReadContext` exposes only bounded read capabilities:

- monotonic time and remaining deadline;
- cancellation state;
- current mount and stable-subject resolution;
- run-scoped resource-claim lookup without mutation;
- render-generation capture and observation;
- bounded diagnostic recording; and
- immutable run, execution-owner, and command identity.

`CommandExecutionContext` adds cooperative frame, tick, event, and predicate
waits plus internal workflow-step execution. It still exposes no cleanup
registration, resource-claim activation/release, mutable command registry,
host service, controller transport, or unrestricted result publisher. The
runner alone owns cleanup checkpoints, claim-plan validation, and post-effect
transaction/claim activation through its private invocation state. The built-in
`registerCleanup` definition receives a narrow `CleanupRegistrationCapability`
in its privileged execution context. That capability exposes only atomic
post-effect transaction-and-claim registration.

Stage-specific context construction therefore enforces framework capability
boundaries. Command conformance tests remain responsible for detecting direct
native or global mutation that no Lua capability object can technically prevent.
Driver modules continue to avoid imports from `dwarfspec.host`.

## Workflows and internal steps

Commands such as `mountSaveGame()` are workflows rather than single native
actions. A workflow has one public command identity, one deadline, and one
terminal result. It contains named internal steps with their own retryable
preflight and verification callbacks. Each step occurs once in sequence; its
mutation follows its explicit `ONCE` or `EXPLICIT_RETRY_SAFE` execution policy.
The containing `CommandDefinition` has kind `WORKFLOW`, supplies its
`WorkflowDefinition` through the `workflow` field, and omits the direct
`execute` callback. The workflow runner is that command's primary execution
boundary. The containing definition uses `ONCE` and `EXECUTION_RECEIPT`; its
completed frozen workflow state proves that every step's own intrinsic policy
passed. Claims, execution retry, intrinsic callbacks, and cleanup attach to the
individual steps rather than being duplicated at the containing level. Optional
caller verification still runs against the containing public result.

The internal contract is deliberately the command contract without public
registration or an independent timeout:

```lua
---@class dwarfspec.WorkflowState
---@field request any
---@field outputs table<string, dwarfspec.WorkflowOutput>

---@class dwarfspec.WorkflowOutput
---@field has_value boolean
---@field value? any

---@class dwarfspec.WorkflowDefinition
---@field steps dwarfspec.WorkflowStepDefinition[]
---@field result fun(state: dwarfspec.WorkflowState): any

---@class dwarfspec.WorkflowStepDefinition
---@field name string
---@field kind dwarfspec.ECommandKind QUERY, ASSERTION, ACTION, STATE_SETTER, or FIXTURE; nested WORKFLOW is forbidden.
---@field preflight fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState): dwarfspec.GateResult
---@field claims? fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState, ready: any): dwarfspec.ResourceClaimPlanEntry[]
---@field execute fun(context: dwarfspec.CommandExecutionContext, state: dwarfspec.WorkflowState, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field execution_retry_policy dwarfspec.EExecutionRetryPolicy
---@field operation_key? fun(state: dwarfspec.WorkflowState): string
---@field intrinsic_verification dwarfspec.EIntrinsicVerificationKind
---@field verify? fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState, receipt: any): dwarfspec.IntrinsicVerificationResult
---@field cleanup? dwarfspec.CommandCleanupPolicy
---@field diagnostics? fun(state: dwarfspec.WorkflowState, receipt: any): table
```

Each step uses the same gate and execution-result constructors, explicit
effect-receipt rule, `claims` plan-validation boundary, retry policy, cleanup
registration service, forced command-lifetime cleanup before an execution
retry, intrinsic-verification policy, and bounded diagnostics as a public
command of its declared kind. Query and assertion steps poll their primary
`GateResult`; mutating step kinds return `ExecutionResult`. Nested `WORKFLOW`
steps are rejected so composition has one explicit state and result boundary.
The workflow runner structurally validates step definitions when it validates
the containing command. Step names are unique within the workflow.

The workflow runner creates an immutable `WorkflowState` whose `request` is the
defensively copied normalized command request and whose initially empty
`outputs` map is keyed by step name. A successful mutating
`command.executed(step_output, receipt, effect_receipt)` commits its public
result; a successful query or assertion `command.ready(value, evidence)` commits
its ready value. The runner validates a non-nil value as bounded plain data,
defensively copies and freezes it, then stores a frozen `WorkflowOutput` record.
`has_value=false` represents a successful nil output, so the step key remains
present and distinguishable from a step that never completed. Retry, fatal,
thrown, cancelled, and timed-out outcomes do not commit an output. Later steps
receive the new immutable state and re-resolve live native objects from stable
descriptors in prior output records; outputs never contain callbacks, userdata,
or assumed-live targets.

After all steps pass, a bounded, synchronous, non-yielding result projector
derives the workflow command's stable public result from the completed state.
The containing command may use that state as its private verification receipt,
but it omits a composite `effect_receipt`: step effects have already been
registered exactly once by the workflow runner. Workflow state is not a
substitute for an immutable cleanup effect receipt, and a step cannot invent
callbacks dynamically or bypass cleanup registration merely because it is not
public.

A thrown or invalid result projection fails the containing command at the
primary-execution stage. No additional step output is committed, and the normal
command finally boundary still expends command-lifetime cleanup while retaining
owner-lifetime transactions.

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
cleanup transaction and owner, but exclusive-resource checks query the complete
run index. A nested test therefore cannot claim a unit, tile reservation,
screen, pointer state, or other exclusive resource already claimed by its suite
merely because its cleanup registry is different. An active claim without a
registered transaction is invalid state.

Commands may use explicit compatible-sharing or dependency relationships when
a domain contract permits them. Compatibility is never inferred from nesting
or matching coordinates. Consuming or transferring a claim requires an
explicit command contract; otherwise a command may consume only a claim owned
by its exact owner. Cleanup registries and execution indexes remain private to
their individual owners even when the resource index relates their claims.

The shared dependency mechanism is `DirectedAcyclicGraph`, instantiated with
active claim IDs and prerequisite-to-dependent edges according to its
prerequisite proposal.
`ResourceDependencyIndex` owns DwarfSpec-specific lifetime-direction validation
and claim policy. `CleanupPlanner` owns deterministic reverse-topological cleanup
planning. Commands declare domain relationships through
`ResourceDependencyIndex` instead of implementing local dependency lists or
cleanup ordering. During inert plan validation, `CleanupPlanner` projects the
inert plan as one simulated transaction node together with every existing owning
transaction and validates the derived `CleanupTransactionDependencyGraph`.
Validation fails before mutation if that projection cycles; claim-level
acyclicity alone is insufficient because one transaction may own multiple
claims. This simulation changes no graph or ownership state.

A dependent claim must have a lifetime no longer than every prerequisite.
Command lifetime is nested within its tagged execution owner, a test attempt is
nested within its suite execution, and a suite execution is nested within the
service run. Sibling or otherwise incomparable owners cannot form a dependency
and are rejected by `ResourceDependencyIndex` before graph edge insertion. A
separate explicit resource-transfer command may rehome a claim before a
dependency is proposed, but dependency insertion itself never transfers either
the claim or cleanup ownership. An owning cleanup
transaction cannot release a prerequisite while an active dependent remains.

A resource claim becomes active only when an effect receipt proves that cleanup
is required and `CleanupRegistrationService` creates the claim and executable
cleanup transaction together. A `COMMAND` transaction gives its claims command
lifetime while retaining the tagged suite/test owner and command correlation; an
`OWNER` transaction gives them the active suite-execution or test-attempt
lifetime. Retry effects use forced `COMMAND` lifetime. Service-owned effects use
`SERVICE_RUN` ownership. Successful verified cleanup or verified abandonment
releases the transaction's claims. Failed or unconfirmed cleanup leaves them
unresolved and contributes to executor quarantine until the recovery contract
proves the resource clean. Historical cleanup state remains authoritative in
the service journal; the runtime index and graph must not become competing
result ledgers.

The definition's `claims(context, request, ready)` method is the declarative
pre-execution boundary for the inert plan. It runs after successful preflight
and volatile-target validation, so it may use the freshly resolved ready value,
but it is read-only and cannot mutate ownership. A plan entry may name an exact
existing resource or a provisional creation identity derived from the command
invocation ID when the native ID cannot exist before execution. For an
`EXPLICIT_RETRY_SAFE` definition, that derivation also includes the frozen
stable operation key; an `ONCE` definition neither has nor requires one.
Relationships within the plan use local claim keys; relationships to
active claims use validated `ResourceClaimReference` values obtained from an
owning transaction or a command result whose contract explicitly publishes
them.

The runner treats all entries returned for one attempt as the possible claim set
of that attempt's one cleanup transaction, even though the later effect receipt
may bind only a subset. This conservative simulation may reject a plan whose
eventual subset could have been safe; definitions split such work into separate
workflow steps rather than deferring safety discovery until after mutation.
After an execution retry has cleaned every previous-attempt effect, the runner
re-runs preflight, target validation, and claim-plan validation before another
attempt. Cleanup policy `resources(effect_receipt)` selects planned entries by
`claim_key` and binds provisional entries to concrete stable identities. The
runner rejects duplicate or unknown keys, incompatible identities, new
relationships, or a pre-existing exclusive resource absent from the validated
plan.

The run-scoped runner serializes each mutating attempt from final claim-plan
validation through effect registration. Primary execution remains bounded and
may cooperatively yield, but another DwarfSpec mutating command or ownership-index
mutation cannot enter that protected window; nested read-only commands remain
legal. The registration service nevertheless revalidates the bound subset
against the current index. On the normal path it
allocates one run-unique transaction ID, registers the cleanup transaction,
creates every active claim with that same owning transaction ID, inserts the
claim and derived transaction graph edges, and publishes the registration event
as one service mutation.

If post-effect revalidation exposes an adapter-contract violation or an
unexpected ownership conflict, the effect must not become untracked. The service
still records its cleanup transaction and fail-closed conflicted claim records,
the command fails at cleanup registration, and executor quarantine applies.
Those conflicted records preserve both ownership assertions for diagnostics and
block further incompatible work until cleanup and recovery establish the actual
resource state.

### Caller post-effect resource claims

Downstream callers create the effect first and then pass exact
`ResourceClaimRegistration[]` descriptors as part of
`ds.registerCleanup(registration, command_options)`. The service creates the
caller-visible cleanup transaction and all active claims together. Local
relationships name another `claim_key` in the same registration; relationships
to existing active claims use validated `ResourceClaimReference` values.
Caller-supplied claims cannot be provisional and cannot exist independently of
the returned transaction.

This low-level caller sequence cannot make arbitrary mutation failure-atomic: an
error can still occur after native mutation but before `registerCleanup()`.
Failure-sensitive native construction should therefore be implemented as a
project-defined verified command, whose adapter can return a structured partial
effect receipt. Direct post-effect registration remains supported for callers
that can keep the mutation-and-registration sequence bounded and non-yielding.

### Cleanup registration service and public command

One run-scoped internal `CleanupRegistrationService` is the sole mutation
boundary for owner-local cleanup registries, execution indexes, transaction
identity allocation, receipt freezing, resource linking, and registration
journal events. The command runner uses this service when an execution outcome
returns an effect receipt. Internal command implementations receive no general
registry access and cannot construct transaction handles themselves.

`ds.registerCleanup(registration, command_options)` is also a real public
`ACTION` command routed
through the common runner. Its preflight proves that the current suite or test
owner still accepts registrations. Its `claims` projection is empty because the
caller's effect already exists. Its `ONCE` primary execution asks
`CleanupRegistrationService` to register the caller-supplied immutable receipt,
restore operation, required verification operation, and exact
`ResourceClaimRegistration[]` together. Its intrinsic verification proves that
the returned transaction is pending under the expected owner, owns every
activated claim, and that its registration event exists, then
it returns the caller-visible handle. Its execution outcome uses the transaction
identity as verification receipt and omits `effect_receipt`: the registration
transaction is the command's intended framework effect, but it is not itself an
effect requiring a second cleanup transaction. The runner therefore does not
recursively register one through `CommandCleanupPolicy`.

This specialized public command is the supported downstream entry point to the
same service, not a bypass around command execution. Command definitions use
immutable definition-owned cleanup policies and explicit effect receipts;
downstream callers use `ds.registerCleanup()` because their callbacks and
receipt are invocation data. Both paths produce the same transaction type,
owner attribution, lifecycle, journal events, manual-execution behavior, and
teardown behavior.

Because caller mutation precedes this command, a resource conflict or invalid
relationship discovered during registration cannot justify dropping the cleanup
receipt. The service registers a fail-closed transaction, records conflicted
ownership evidence, and returns a structured command failure. The transaction
remains available to owner teardown even when the caller never receives its
handle. Purely structural invocation errors that prevent DwarfSpec from safely
receiving the receipt or callbacks remain caller contract violations; the
project-defined command path is required when that failure window matters.

`CleanupRegistrationService` also owns one runner-only
`abandonSelfRolledBack(transaction_id, proof)` operation. It accepts only a
pending internal transaction owned by the current invocation and the bounded
proof carried by `command.effect_absent(...)`. In one atomic transition it
removes the transaction from the pending registry, records `abandoned`, releases
all of its claims, and publishes `cleanup.transaction_abandoned`. It is not
exposed through `CleanupExecutionContext`, `CleanupTransaction`, project command
contexts, or the public `ds` facade. If validation or the atomic transition
fails, the transaction remains pending and the command follows its normal
verification-failure and eventual cleanup path; it is never silently marked
abandoned.

### Cleanup transaction lifecycle

The cleanup registry owns executable cleanup transactions rather than bare
callbacks. Registration returns a handle with an explicit lifecycle:

```lua
---@class dwarfspec.CleanupTransaction
---Manually expends pending cleanup; raises after recording a cleanup failure.
---The boolean is returned only on the normal success/already-expended path.
---@field execute fun(self: dwarfspec.CleanupTransaction, reason?: string): boolean
---@field isPending fun(self: dwarfspec.CleanupTransaction): boolean
---Returns immutable references for dependency-capable claims owned by this transaction.
---@field claimReferences fun(self: dwarfspec.CleanupTransaction): dwarfspec.ResourceClaimReference[]
```

`claimReferences()` returns a frozen copy and grants no mutation capability.
References remain usable only while their claims are active; successful cleanup,
abandonment or run termination makes them stale and subsequent index
validation rejects them.

Mutable lifecycle-handle methods use one central stage guard. Manual
`transaction:execute()` is legal from ordinary suite/test hook or body code and
from runner/finalizer internals. It is rejected from command normalization,
preflight, claim planning, primary execution, intrinsic or caller verification,
workflow callbacks, cleanup restore, and cleanup verification. Read-only
`isPending()` and `claimReferences()` remain legal wherever their owning object
is otherwise accessible. This prevents a captured handle from bypassing the
restricted command and cleanup contexts.

A transaction is registered only after its effect exists. It contains a label,
restore operation, required verification operation, immutable cleanup receipt,
stable cleanup evidence, and one of
`pending`, `running`, `complete`, `failed`, `abandoned`, or `unconfirmed`. The
first two states are nonterminal; the remaining four are terminal dispositions.
`abandoned` is restricted to an exceptional internal transaction whose effect
receipt was registered but whose intrinsic verification subsequently returns
`command.effect_absent(...)` with an independent stable-identity observation
proving that the native operation self-rolled back before publication and
requires no restoration. This typed proof is the transaction's independent
absence verification and must satisfy the same stable-identity and bounded
evidence requirements as cleanup verification. The runner-only service
transition releases every owned claim while recording the terminal event.
`abandoned` contributes confirmed cleanup only when both the absence proof and
claim release succeed; otherwise the transaction remains pending for ordinary
cleanup and eventual terminalization.
`unconfirmed` means interruption or recoverable execution-host failure prevented
the still-running automation service from establishing a normal cleanup outcome.
Caller registrations have owner lifetime: test-attempt lifetime when created
inside an attempt, or suite-execution lifetime when created in suite-level
setup/teardown. Internal registrations may instead have command lifetime for
transient input flags or similar state. The lifetime enum therefore contains
`OWNER` and `COMMAND`; it does not encode test versus suite separately because
the tagged owner identity supplies that distinction.

Calling `transaction:execute()` manually first applies the lifecycle-stage guard
and asks `CleanupPlanner` whether any active dependent claim blocks this
transaction. A blocked call raises bounded `dependency_blocked` evidence without
publishing `cleanup.transaction_started`, invoking callbacks, removing the
transaction, or changing its `pending` state. After dependents are expended, the
caller may try again. An eligible call removes the pending transaction from the
active registry before invoking restore and verification. The handle
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
the same planner for command-lifetime transactions. The planner orders the
derived transaction graph, not claim nodes individually, so one multi-claim
transaction is always executed atomically in one position. Claim linking has
already rejected any transaction-level cycle. One failure does not prevent
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
adapter returns a structured failure with an explicit effect receipt; a stable
operation key needed to rediscover the partial effect is data within that
receipt. An unobservable mutation followed by a thrown error violates the
adapter contract.

State setters capture their inherited baseline before mutation, then register
an owner-lifetime transaction immediately after the effect is conclusively
observed. Fixture commands validate an inert exclusive-claim plan before native
construction, then atomically register cleanup and activate claims from the
returned stable identity before verification or publication. Command-lifetime
transactions are automatically expended in the command's finally boundary. A
command failure does not drain
unrelated or owner-lifetime transactions because callers may catch the failure
and continue the test.

Every cleanup transaction that mutates external state has an independent
verification operation. Cleanup verification is not optional because
`cleanup_confirmed` must remain authoritative. Cleanup uses stable identities
and scalar snapshots, continues after individual failures, and aggregates all
labeled failures. Ordinary execution invokes the registered verification
callback; the exceptional `abandoned` path uses its independently observed typed
absence proof as the equivalent terminal verification defined above.

Each call that expends a transaction receives a new finite cleanup deadline,
independent of the command deadline that caused or preceded cleanup. Timeout
precedence is the registration's `cleanup_timeout_ms`, then
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
receive a restricted cleanup execution context plus the same immutable cleanup
receipt. The receipt is their only transaction-specific data; they do not
receive mutable transaction state or capture required cleanup identity through
closure variables. The context exposes only bounded time, cleanup cancellation,
read-only query/assertion execution for verification, and safe diagnostic
recording. It privately supplies owner, state-transition, and journal
attribution capabilities to the engine rather than exposing them to callbacks.
A restore callback does not invoke public commands or register more cleanup.
Verification remains read-only: it may invoke public queries or assertions, but
those nested invocations inherit the cleanup transaction's owner identity,
cleanup cancellation scope, and remaining cleanup deadline rather than starting
a fresh command timeout. A query or assertion nested under a `SERVICE_RUN`
transaction therefore uses the reserved `SERVICE_RUN` execution-owner scope and
run identity. It remains a child of the cleanup verification operation and does
not make caller-initiated service-run commands legal. Mutating commands and
cleanup registration are fatal contract errors from cleanup verification.
Nested verification commands retain normal child command events while the
transaction remains the owner of the cleanup outcome.

Cleanup receives a fresh cancellation scope when transaction execution starts.
Cancellation or deadline expiry of the originating command, test body, or suite
hook triggers cleanup but does not pre-cancel that scope. Only cleanup's own
deadline or an explicit emergency signal that the execution host is no longer
safe can cancel it. Consequently a nested cleanup-verification query never
inherits an already-cancelled parent-command token. If emergency cancellation
prevents a conclusive cleanup outcome while the service survives, the normal
`unconfirmed` terminalization rule applies.

An expired verification deadline does not discard the execution receipt. The
receipt remains available to its registered transaction so partial or
successful mutation can be reversed even when the command never returned to
test code.

### Cleanup history and result reporting

The active pending registry and cleanup history have different responsibilities.
Each cleanup owner scope owns its own active registry and mutable cleanup
execution index. An owner is the service run, a suite execution, or a test
attempt nested within that suite execution. The registry contains only
transactions that remain eligible for automatic execution. The execution index retains the
in-process handles, private receipts, and current states required to execute
those transactions; it is never shared between owners. Removing a transaction
from the active registry therefore means only that teardown must not execute it
again. Its already-published lifecycle events remain in the service journal.

Registration assigns a stable transaction ID and registration ordinal before
the transaction can protect or publish mutable state. The transaction ID is
unique within the run, while the registration ordinal is local to the owning
service run, suite execution, or test attempt. Its safe event projection contains only
bounded, serialization-safe data:

- cleanup-owner scope and owner identity, plus repeat index, stable suite
  identity, and test identity when applicable;
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
authoritative cleanup history. Every transaction lifecycle event carries
`ECleanupOwnerScope`, its owner ID, transaction ID, and owner-local registration
ordinal, plus repeat, suite, test, and command correlation when applicable.
Consumers partition the journal by tagged owner identity; service-run, suite,
test, and repeated executions never share ownership or result sets.
Service-owned transactions use the same lifecycle event family tagged
`SERVICE_RUN` and a run-level result projection; they are never attributed to an
arbitrary suite or test.

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
  publication without requiring restoration, including the bounded abandonment
  proof and verified claim-release outcome.

If interruption or a recoverable execution-host failure prevents a registered
transaction from reaching one of those normal dispositions while the automation
service remains alive, terminalization records it as `unconfirmed` rather than
silently omitting it and publishes exactly one corresponding
`cleanup.transaction_finished` event. A terminal service run, suite execution,
or test attempt retained by that service therefore reports every transaction
registered to that owner with exactly one disposition: `complete`, `failed`,
`abandoned`, or `unconfirmed`. Repeated manual execution does not add a second
terminal event.

Loss of the DFHack process or automation-service instance is outside this
complete-ledger guarantee: its journal is intentionally process-local and cannot
publish new terminal events after destruction. An external persistence owner may
report connection or interruption failure using evidence it already received,
but it must not synthesize missing transaction registrations or dispositions.

### Cleanup ownership and finalization

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
their parent. Caller-initiated public commands and cleanup registrations remain
invalid when neither a suite execution nor a test attempt is active. The sole
command exception is a read-only query or assertion invoked as a child of
`SERVICE_RUN` cleanup verification. Service-owned run cleanup is a separate
owner scope and does not appear in either suite/test projection.

After attempt-local teardown hooks return, registration closes and automatic
cleanup executes every transaction that remains pending. DwarfSpec then
terminalizes interrupted transactions, materializes the attempt's
`cleanup_transactions` result, and only afterward publishes `test.finished`.
The event's behavior status remains distinct from cleanup disposition; failed
or unconfirmed cleanup is reported separately and still contributes to the run
failure and quarantine rules. If interruption prevents the ordinary test
callback from finishing, the emergency finalizer attempts remaining test-owned
transactions in dependency-safe reverse-topological order with LIFO tie-breaking
whenever the execution host is still usable. Run terminalization
then synthesizes the attempt result and marks only transactions that remain
unresolved `unconfirmed` before `run.finished`.

After suite-level teardown hooks return, suite registration closes and automatic
cleanup executes every remaining suite-owned transaction in
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
terminalized `unconfirmed`; no state is reassigned to the first or last test.

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

After all suite and test owners have closed, service-run cleanup registration
closes. `CleanupPlanner` then executes every remaining `SERVICE_RUN` transaction
in dependency-safe reverse-topological order, including dependencies on any
still-active suite or test claims. A prerequisite that remains blocked by a
failed or unconfirmed dependent is recorded as `dependency_blocked` and is not
silently released; normal failure, terminalization, and executor-quarantine
rules apply. The service finalizer folds the same lifecycle events into
`host_report.service_cleanup_transactions` before `run.finished`. Thus a
service-run effect, its transaction ID, its active claims, and its eventual
terminal disposition use the same ledger as suite- and test-owned cleanup while
remaining a distinct result projection.

The controller validates all three owner-scope projections against the complete
journal and persists them unchanged; it does not independently interpret
cleanup behavior.
Result-schema validation rejects duplicate IDs, missing terminal dispositions,
inconsistent journal/result outcomes, or a transaction attributed to the wrong
owner scope. The persisted run result retains the complete event journal and
the service-run, suite-execution, and test-attempt projections, allowing later
result-file readers to inspect the same history.

The service publishes these events through its existing append-only journal and
cursor APIs. Live consumers can therefore observe registration and state
changes by folding the selected service, suite, or attempt owner's events
without polling private cleanup objects. Completed-result consumers use the
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
service-run inspector, suite-execution inspector, or test-attempt inspector may
enumerate successful, failed, abandoned, and unconfirmed transactions. Failures and unconfirmed
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
service-run, suite-execution, or test-attempt ID, repeat index, and stable
suite/test identity as applicable. Top-level commands have no parent and use
their own invocation ID as the root ID. Child queries and workflow steps use
distinct invocation IDs even when their command names and normalized arguments
are identical, and they inherit the parent's owner scope exactly.

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

- `context.lua` constructs the read-only, execution, and privileged
  cleanup-registration capability views
  without exposing runner state.
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

The host cleanup subsystem's run-scoped `CleanupRegistrationService` owns the
only registration mutation API and coordinates separate pending-only owner
registries with stable registration ordinals and mutable cleanup execution
indexes for suite executions and their nested test attempts. The runner and the
privileged `registerCleanup` command definition receive narrow service
capabilities; ordinary command definitions do not. A run-scoped
`ResourceDependencyIndex` relates active claims across
service-run, suite-execution, test-attempt, and command-invocation levels while
preserving those owner-local cleanup registries. Its
`DirectedAcyclicGraph` owns generic dependency structure and ordering,
`ResourceDependencyIndex` owns resource and lifetime policy, and
`CleanupPlanner` produces transaction execution plans for every command family;
individual adapters do not duplicate any of that logic.
The automation service remains the sole publisher and owns the authoritative
run-scoped event journal. Its service-run, suite, and test-attempt finalizers
fold the selected owner's transaction events into terminal result projections.
Protocol modules own execution-owner and cleanup-owner scopes, transaction event
types, disposition and lifetime enums, and journal/result validation. The controller result interpreter
validates and persists the supplied journal and owner-scoped projections
without interpreting pending registry state or cleanup semantics.

The root `dwarfspec.ds` module builds the context factory and registry, then
binds thin public functions that invoke the runner. It contains no duplicate
pointer, input, game-state, or mount command implementation.

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
- distinct verification and effect receipts for executed, retry, and failed
  outcomes, including explicit no-effect outcomes and rejection of effect
  receipts without a cleanup policy;
- structural definition validation separately from documented retry-safety and
  execution-receipt qualification fixtures;
- workflow-step conformance for gates, claims, execution outcomes, retry,
  effect-driven cleanup, verification, child events, shared deadlines, unique
  step names, supported non-workflow step kinds, query/assertion gate outcomes,
  mutating execution outcomes, immutable named outputs, no output commit on
  nonsuccess, final result projection, and rejection of an unattached or nested
  workflow definition;
- one `CleanupRegistrationService` used by runner-managed effect cleanup and by
  the fully runner-routed public `registerCleanup` command, without recursive
  transaction registration;
- downstream post-effect registration of exact resource claims, owner isolation,
  atomic transaction-and-claim creation, rejection of duplicate or invalid
  relationships, and fail-closed retention of both cleanup and conflict evidence
  when semantic validation fails after the effect exists;
- cleanup receipt validation, defensive freezing, identical callback delivery,
  runtime enforcement of required receipt data without attempting to inspect
  callback closure semantics, and runner-only exceptional self-rollback
  abandonment with bounded proof, claim release, and pending fallback when the
  atomic transition fails;
- cleanup state transitions through every terminal disposition, including an
  exactly-once journal event for `unconfirmed`;
- inert `claims` planning and validation before mutation without index changes,
  cross-level exclusive-conflict detection, explicit compatible sharing and
  dependency relationships, distinct local claim keys and validated opaque
  existing-claim references, exact and provisional claim keys, deterministic
  effect-receipt binding, rejection of duplicate/unknown/incompatible bindings,
  proof that structured no-effect, thrown, cancelled, and pre-effect timed-out
  exits create no active claim, `DirectedAcyclicGraph` cycle validation,
  `ResourceDependencyIndex` lifetime-direction validation, pre-mutation
  rejection of cycles in the simulated claim and transaction graphs,
  defensive link-time revalidation, transaction-level
  reverse-topological cleanup with LIFO tie-breaking, rejection of prerequisite-claim release while
  a dependent claim remains active, deterministic `dependency_blocked` failure
  materialization, and verified release or quarantine retention;
- serialization of each mutating attempt from final inert-plan validation
  through atomic post-effect transaction-and-claim registration, including
  cooperative primary-execution yields and permitted nested read-only commands;
- one-shot restoration and retryable cleanup verification under an independent
  finite cleanup deadline, including restoration errors followed by attempted
  verification and cleanup timeout reporting, plus a fresh cleanup cancellation
  scope after parent command or lifecycle cancellation;
- suite-execution attribution across suite setup and teardown, test-attempt
  attribution across attempt setup, body, and teardown, most-specific-scope
  selection, rejection of caller-initiated commands outside both active scopes,
  reserved `SERVICE_RUN` attribution for read-only cleanup-verification children,
  and `test.finished` and `suite.finished` ordering after their cleanup-result
  materialization;
- service-run ownership, transaction IDs, dependency-safe finalization after
  suite/test owners close, run-level result materialization before
  `run.finished`, and quarantine when failed dependents block a prerequisite;
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
- read-only public queries and assertions nested from preflight or verification
  inheriting the exact parent deadline, cancellation, owner, stage, and event
  identity, with nested mutations rejected;
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
- command failures reach Busted as lifecycle errors attributed to the active
  suite execution or test attempt with their stage preserved;
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

- Add protocol enums, settings, structural definition validation, the distinct
  verification/effect-receipt outcome constructors, `claims` projection,
  execution-retry policy and outcomes, deadline handling, the command context,
  workflow-step contract, and the runner.
- Add suite-execution and test-attempt cleanup indexes, stable transaction
  identities, `CleanupRegistrationService`, the runner-routed public
  `registerCleanup` command, authoritative
  run-journal lifecycle events, and the service-materialized owner-scoped
  cleanup result projections.
- First implement and qualify the prerequisite
  [directed acyclic graph utility proposal](directed-acyclic-graph-proposal.md).
- Add the run-scoped `ResourceDependencyIndex`, its graph instance, cross-level
  conflict and lifetime policy, `CleanupPlanner`, and verified claim release.
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
`disableUnitsAi`, and `runUntil`. This proposal supersedes any conflicting
command execution, timeout placement, cleanup-transaction, retry, migration, or
validation-cadence language in that document. In particular:

- `registerCleanup` is the public post-effect command backed by the internal
  `CleanupRegistrationService` and returns the manually executable transaction
  defined here while atomically activating any exact caller resource claims;
- `reserveMapTiles` remains a domain fixture command whose logical reservation
  is itself a confirmed effect; it is not a generic pre-effect resource-claim
  reservation facility;
- command `timeout_ms` belongs to trailing `CommandOptions`; the distinct
  `CleanupRegistration.cleanup_timeout_ms` controls later transaction execution,
  while a frame budget remains a logical wait option where applicable;
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
- registry validation accepts only structurally valid definitions, while
  capability boundaries and conformance tests enforce behavioral callback
  contracts that function inspection cannot prove;
- preflight, claims, and verification receive read-only contexts; primary
  execution receives no cleanup or resource-index mutation capability; only the
  runner and the privileged `registerCleanup` lifecycle command can reach the
  cleanup-registration capability;
- every mutating primary operation is exactly once by default;
- `EXPLICIT_RETRY_SAFE` is fully implemented, retries only explicit outcomes
  under one stable operation key and deadline, preserves attempt receipts,
  executes and verifies cleanup for every prior attempt effect before retrying,
  and cannot pass command-specific qualification without its documented
  idempotency proof and conformance fixture;
- intrinsic verification exists wherever the declared framework effect is
  independently observable;
- caller verification is optional, retryable, documented, and unable to weaken
  intrinsic verification;
- nested read-only preflight and verification commands inherit the parent
  deadline and appear as child events with unique invocation, parent, owner, and
  stage identities;
- command timeout errors identify the exact lifecycle stage and last bounded
  observation;
- execution outcomes distinguish private verification evidence from an explicit
  optional effect receipt, and omission unambiguously means that no
  cleanup-requiring effect occurred;
- command-owned effects register cleanup synchronously from their explicit
  effect receipts before later fallible work, yielding, verification, retry, or
  publication;
- every retry-attempt effect is cleaned with forced command lifetime before a
  later attempt, while terminal executed or failed effects use the definition's
  declared cleanup lifetime;
- each workflow step uses the common gate, claims, outcome, retry, cleanup,
  verification, deadline, and child-event contracts rather than an implicit
  mutation path;
- every `WORKFLOW` command explicitly owns one validated `WorkflowDefinition`
  instead of a direct execute callback; each step declares a supported
  non-workflow kind and uses that kind's gate or execution-result protocol;
- workflow state consists only of the immutable normalized request and bounded
  frozen outputs keyed by unique successful step names; nonsuccessful outcomes
  commit no output, and one pure result projector derives the public result;
- resource claims are tracked across service-run, suite-execution,
  test-attempt, and command-invocation levels, with exclusive conflicts checked
  across the complete run rather than only within one cleanup registry;
- mutating definitions project claims after preflight through a read-only
  `claims` method; the runner validates that inert plan before execution and
  later binds effect-linked resources against its stable claim keys without
  creating index state before the effect;
- the runner serializes the interval from a mutating attempt's final claim-plan
  validation through atomic effect registration, even across cooperative yields,
  so no competing DwarfSpec ownership mutation invalidates the checked plan;
- resource relationships distinguish local request keys from validated opaque
  references to existing active claims, and public references are exposed only
  by owning transactions or documented resource-producing command results;
- every active resource claim represents a confirmed effect and belongs to
  exactly one registered cleanup transaction; no-effect exits leave no claim
  state to release, and post-effect conflicts retain fail-closed ownership and
  cleanup evidence for quarantine and recovery;
- the shared `DirectedAcyclicGraph` abstraction rejects cycles in both its
  active-claim and planner-derived transaction-graph instances,
  `ResourceDependencyIndex` rejects invalid lifetime direction, and
  `CleanupPlanner` rejects cycles in the transaction graph simulated from an
  inert plan before mutation and defensively revalidates it when linking
  and before planning dependent-before-prerequisite transaction cleanup; it
  uses LIFO only to order
  independent transactions and never transfers ownership implicitly;
- one internal `CleanupRegistrationService` creates all transactions; the
  runner uses it for command effect receipts, while the public runner-routed
  `registerCleanup` command uses it for downstream registration without
  recursively creating a second transaction;
- downstream callers can supply exact post-effect resource registrations to
  `registerCleanup`, which creates the cleanup transaction and active claims as
  one service mutation; every resulting claim carries that transaction ID, and
  a semantic registration failure retains a fail-closed transaction and
  conflicted ownership evidence instead of losing the cleanup receipt;
- caller cleanup registrations return manually executable transactions, and
  teardown executes every transaction that remains pending;
- cleanup callbacks receive a required immutable transaction receipt, and the
  runtime validates that receipt without claiming it can enforce callback
  closure semantics;
- caller cleanup registration requires an independent verification operation;
- exceptional internal abandonment is available only through a runner-owned
  transition after typed intrinsic evidence proves self-rollback; it records
  bounded proof, releases every claim, and otherwise leaves the transaction
  pending for ordinary cleanup;
- cleanup restoration is one-shot, cleanup verification is retryable, and every
  cleanup execution has a finite deadline independent of its owning command;
- command-lifetime and owner-lifetime automatic cleanup execute in
  dependency-safe reverse-topological order, with reverse registration order
  used only for independent transactions within their respective scope;
- test-attempt cleanup closes and its result is materialized before
  `test.finished`; suite-execution cleanup closes and its result is materialized
  before `suite.finished`; service-owned run cleanup closes after suite/test
  finalization, uses the same transaction lifecycle, and is materialized at
  `host_report.service_cleanup_transactions` before `run.finished`;
- removing or expending a transaction never removes its lifecycle events from
  the authoritative service journal;
- every registered transaction owned by a terminal service run, suite
  execution, or test attempt retained by a surviving service appears exactly
  once in that owner's result with `complete`, `failed`, `abandoned`, or
  `unconfirmed` disposition;
- the service event journal and persisted result expose consistent transaction
  identities, ordering, attribution, outcomes, and bounded evidence;
- the journal remains the sole historical source of truth, while live consumers
  fold owner-tagged events and completed-result consumers may use the
  service-materialized projections at
  `host_report.service_cleanup_transactions`,
  `host_report.suite_executions[].cleanup_transactions` and
  `host_report.test_attempts[].cleanup_transactions`;
- cleanup verification remains independent of the expired command deadline;
- cleanup execution receives a fresh cancellation scope instead of inheriting
  an already-cancelled command, test-body, or suite-hook token;
- cleanup restore callbacks cannot recursively invoke public commands, while
  read-only commands used by cleanup verification inherit the transaction's
  owner and remaining cleanup deadline, including reserved `SERVICE_RUN`
  command ownership for service-cleanup verification children;
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
