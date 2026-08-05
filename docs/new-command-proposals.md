# Managed native-fixture commands proposal

## Status

This document proposes a set of general-purpose DwarfSpec commands for
constructing, observing, advancing, and cleaning up native Dwarf Fortress test
fixtures. It is an exploratory design proposal, not an implementation checklist
and not a description of shipped behavior.

`verified-command-execution-proposal.md` is authoritative for command
definitions, deadlines, preflight, retry, receipts, caller verification,
cleanup transactions, migration, and validation cadence. This document remains
authoritative only for the fixture commands' domain behavior. Conflicting
execution or delivery language here is superseded by that proposal.

The domain-neutral `DirectedAcyclicGraph` used here is specified by the
prerequisite
[directed acyclic graph utility proposal](directed-acyclic-graph-proposal.md).
This document specifies only fixture-domain resource and cleanup policy.

The proposed public entry points are:

```lua
ds.reserveResourceClaims(claims, command_options)
ds.registerCleanup(registration, command_options)
ds.spawnItem(options)
ds.createStockpile(options)
ds.reserveMapTiles(options)
ds.spyJobs(options)
ds.queryUnits(options)
ds.disableUnitsAi(unit_ids)
ds.runUntil(description, query, options)
```

## Accepted direction

- Every mutating fixture command is scoped to the most specific active cleanup
  owner: the current test attempt, or the suite execution when called from
  suite-level setup/teardown. It registers cleanup immediately after an effect
  is conclusively identified and before later fallible work, yielding,
  verification, retry, or publication to test code.
- Cleanup participates in DwarfSpec's shared dependency-aware cleanup,
  verification, reporting, and executor-quarantine behavior; independent
  transactions retain LIFO ordering.
- Commands create and own their fixture resources. They do not borrow organic
  items, buildings, jobs, or units and later pretend those resources were
  created by DwarfSpec.
- Native resources are exposed through stable numeric IDs and immutable scalar
  snapshots. Commands do not promise that a mutable DF userdata reference
  remains valid across frames, world transitions, or reloads.
- Query results have deterministic ordering. Unless a command states otherwise,
  numeric IDs are returned in ascending order.
- `ds.queryUnits()` returns an array of unit IDs, not unit instances.
- `ds.queryUnits()` accepts built-in filters through a
  `UnitQueryFilterFlags` structure and an optional predicate that receives the
  live unit instance.
- Unit filters include independent `pets` and `animals` fields backed by the
  canonical DFHack classifications.
- `ds.disableUnitsAi()` temporarily sets the native inactive flag for eligible
  units without removing them from `world.units.active`, clearing their jobs,
  or discarding their paths.
- Inactive-unit ownership covers only DwarfSpec's flag transition. It does not
  claim ownership of the organic unit or promise that unrelated world systems
  cannot inspect or affect it.
- `ds.spyJobs()` follows Busted spy conventions: it installs observation before
  the triggering mutation, buffers calls, and returns a callable spy compatible
  with `assert.spy(...)`.
- `ds.spyJobs()` accepts canonical `df.job_type` enum values. It does not
  introduce a parallel string job-type vocabulary.
- Job-spy calls contain immutable lifecycle-event snapshots, never retained job
  pointers.
- `ds.reserveMapTiles()` creates logical reservations only. It does not mutate
  terrain or restore the loaded save game.
- `ds.runUntil()` restores the caller's prior pause state on success, assertion
  failure, query failure, or timeout.

## Goals

- Make native fixtures self-contained and automatically reversible.
- Ensure project-defined cleanup contributes to DwarfSpec's authoritative
  cleanup result.
- Provide deterministic unit and map-space discovery without embedding
  product-specific eligibility policy in DwarfSpec.
- Make short-lived native job transitions observable even when simulation and
  unit actions are accelerated.
- Allow tests to suspend selected units' ordinary per-unit processing while
  the rest of native simulation continues.
- Prefer canonical DF and DFHack types over duplicated string discriminators.
- Preserve enough diagnostic information to explain selection, observation,
  cleanup, and verification failures.

## Non-goals

- Providing product-specific service, persistence, graph, index, or recipe
  helpers.
- Borrowing and restoring arbitrary organic items, buildings, or jobs.
- Providing a general command that deletes every job related to an arbitrary
  caller-owned item.
- Comparing the entire living world for exact equality before and after an
  example. Organic simulation may legitimately change unrelated state.
- Replacing `ds.setUnitPos()`, `ds.await()`, `ds.setGamePaused()`, or the
  existing game-speed commands.
- Providing an isolated native AI scheduler switch or preventing every global
  world subsystem from inspecting, targeting, colliding with, or otherwise
  accounting for an inactive unit.
- Generalizing the initial stockpile command into arbitrary building
  construction.

## Shared lifecycle contract

### Scope and preconditions

All commands in this proposal execute inside the in-process DwarfSpec test
environment. World-dependent commands require a loaded fortress map and fail
before mutation if their preconditions are not met.

Each suite execution and nested test attempt receives an isolated cleanup
ledger shared by these commands. One run-scoped `ResourceDependencyIndex` tracks
stable resource identities, logical tile reservations, spies, inactive-unit
claims, and their tagged service-run, suite, test, or command owner across all
active lifecycle levels. Its prerequisite `DirectedAcyclicGraph` supplies
validated prerequisite-to-dependent structure, while
`ResourceDependencyIndex` validates cross-level lifetime direction and
`CleanupPlanner` plans dependent-before-prerequisite cleanup;
LIFO orders only independent transactions. Cleanup remains owner-local, while
exclusivity and dependency checks consult the complete resource index.

### Register immediately after a confirmed effect

A mutating command does not register cleanup before an effect exists. It first
validates the cleanup policy and reserves any exclusive resource claim, then
registers cleanup synchronously as soon as execution conclusively returns an
effect receipt and before any later fallible work, yield, verification, retry,
or return to test code:

1. validate and normalize the complete request;
2. reserve any exclusive resource claim required for safe mutation;
3. perform native construction;
4. receive a stable effect or structured partial-effect receipt;
5. register cleanup from that immutable receipt and link the resource claim;
6. verify the constructed resource;
7. return the identity.

If construction fails after native allocation, the adapter must return a
structured failure receipt or stable rediscovery key. The runner registers
cleanup from that receipt before propagating the failure. An adapter may throw
without a receipt only when it guarantees that no effect occurred.

### Cleanup and verification

Cleanup entries are idempotent and continue after individual failures. Each
entry has a restore or removal action followed by an independent verification
action. All failures retain their cleanup label and are aggregated into the
owning suite or test result.

`cleanup_confirmed=true` is emitted only after:

- every cleanup-requiring entry was attempted, while any exceptional internal
  transaction abandoned only after its registered effect was proven to have
  self-rolled back before publication;
- every entry-specific verification passed;
- every job spy and recurring observer was stopped;
- every logical map reservation was released; and
- DwarfSpec's existing lifecycle probes also passed.

An unverified or partially failed cleanup quarantines the executor under the
existing recovery contract.

Cleanup registration also publishes an append-only historical transition for
the owning suite execution or test attempt into the authoritative run-scoped
service journal. Manual execution or teardown removes the transaction from
that owner's active pending registry before callbacks run, but it does not remove
its journal history. The transaction reaches `complete`, `failed`, `abandoned`,
or `unconfirmed` and remains available through owner-tagged journal events and
the service-materialized result at
`host_report.suite_executions[].cleanup_transactions` or
`host_report.test_attempts[].cleanup_transactions`.

The verified command execution proposal owns the detailed transaction-event
schema, stable identity rules, safe evidence projection, and result/journal
consistency requirements. Fixture commands must supply stable labels, ownership
identity, and bounded cleanup evidence required by that contract. They must not
introduce a fixture-specific cleanup history or infer completed transactions
from the remaining pending registry.

## Public types

### `MapPosition`

```lua
---@class dwarfspec.MapPosition
---@field x integer
---@field y integer
---@field z integer
```

`MapPosition` is the shared scalar coordinate type for map fixture commands.
It generalizes the coordinate shape currently exposed for unit positioning
without attaching the value to one resource kind.

### `UnitQueryFilterFlags`

```lua
---@class dwarfspec.UnitQueryFilterFlags
---@field active? boolean
---@field alive? boolean
---@field citizens? boolean
---@field fort_controlled? boolean
---@field pets? boolean
---@field animals? boolean
```

Every field is an optional three-state constraint:

- `nil` does not constrain the classification;
- `true` requires the classification; and
- `false` excludes the classification.

The canonical evaluations are:

| Field             | Evaluation                            |
| ----------------- | ------------------------------------- |
| `active`          | `dfhack.units.isActive(unit)`         |
| `alive`           | `not dfhack.units.isDead(unit)`       |
| `citizens`        | `dfhack.units.isCitizen(unit)`        |
| `fort_controlled` | `dfhack.units.isFortControlled(unit)` |
| `pets`            | `dfhack.units.isPet(unit)`            |
| `animals`         | `dfhack.units.isAnimal(unit)`         |

`pets` and `animals` remain separate constraints even when the underlying DFHack
classifications overlap. DwarfSpec evaluates both when both are supplied; it
does not silently reinterpret `animals` as "non-pet animals". A contradictory
combination simply produces no results unless it can be rejected conclusively
during validation.

### Unit query options

```lua
---@class dwarfspec.UnitQueryOptions
---@field filters? dwarfspec.UnitQueryFilterFlags
---@field exclude_ids? integer[]
---@field predicate? fun(unit: df.unit): boolean
```

The predicate is evaluated after built-in filters and receives the live
`df.unit` instance. It is intended for policies that cannot be generalized into
DwarfSpec. Predicate failures abort the query with the unit ID and original
error preserved in the diagnostic.

### Job lifecycle events

```lua
---@enum dwarfspec.EJobLifecycleEvent
ds.EJobLifecycleEvent = {
    CREATED=1,
    ASSIGNED=2,
    STARTED=3,
    COMPLETED=4,
    CANCELLED=5,
    REMOVED=6,
}
```

The event discriminator is DwarfSpec-owned because it describes observer
boundaries, not a native job type. Job types themselves always use the canonical
`df.job_type` enum.

```lua
---@class dwarfspec.JobSpyOptions
---@field job_type? df.job_type
---@field item_ids? integer[]
---@field building_ids? integer[]
---@field worker_ids? integer[]
---@field position? dwarfspec.MapPosition
---@field events? dwarfspec.EJobLifecycleEvent[]
---@field predicate? fun(job: df.job): boolean
```

```lua
---@class dwarfspec.JobLifecycleSnapshot
---@field sequence integer
---@field event dwarfspec.EJobLifecycleEvent
---@field tick integer
---@field job_id integer
---@field job_type df.job_type
---@field worker_id integer|nil
---@field item_ids integer[]
---@field building_ids integer[]
---@field position dwarfspec.MapPosition
```

Snapshots may gain additive scalar diagnostic fields, but their required fields
and meanings remain stable. Arrays are copied and sorted. No field contains
native userdata.

## Command contracts

### `ds.reserveResourceClaims(claims, command_options)`

The verified command execution proposal owns this general lifecycle command.
It atomically reserves `ResourceClaimRequest[]` before downstream native
mutation and returns an owner-bound `ResourceClaimReservation`. This proposal
uses that handle only as the resource-ownership input to `registerCleanup()`;
it does not define a fixture-specific reservation mechanism. A caller releases
the reservation when no effect is produced or atomically consumes it into the
cleanup transaction after an effect exists.

### `ds.registerCleanup(registration, command_options)`

```lua
---@alias dwarfspec.CleanupReceipt boolean|number|string|table

---@class dwarfspec.CleanupRegistration
---@field label string
---@field receipt dwarfspec.CleanupReceipt
---@field claim_reservation? dwarfspec.ResourceClaimReservation
---@field resource_bindings? dwarfspec.ResourceClaimBinding[]
---@field restore fun(context: dwarfspec.CleanupExecutionContext, receipt: dwarfspec.CleanupReceipt)
---@field verify fun(context: dwarfspec.CleanupExecutionContext, receipt: dwarfspec.CleanupReceipt): boolean|dwarfspec.GateResult|nil
---@field cleanup_timeout_ms? integer

---@class dwarfspec.CleanupTransaction
local CleanupTransaction = {}

---Executes and unregisters this transaction when it is still pending.
---Raises after recording a restore or verification failure.
---@param reason? string
---@return boolean executed_and_verified False only when already expended.
function CleanupTransaction:execute(reason) end

---Returns whether this transaction remains registered for teardown.
---@return boolean
function CleanupTransaction:isPending() end

---@param registration dwarfspec.CleanupRegistration
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.CleanupTransaction
function ds.registerCleanup(registration, command_options) end
```

This public action command routes through the verified command runner and uses
its internal `CleanupRegistrationService`; it does not expose a cleanup registry
directly. It is the foundational downstream command for project-defined native
fixtures and produces the same transaction model as runner-managed command
effects.

Contract:

- `label` is nonempty and appears in cleanup diagnostics.
- `restore` and `verify` execute in the same isolated suite/test environment in
  which they were registered.
- Registration is legal in suite-level setup/teardown and attempt-local
  setup/body/teardown. It belongs to the most specific active suite or attempt
  owner and fails after that owner's cleanup begins.
- `verify` is required so the transaction can contribute authoritative evidence
  to `cleanup_confirmed`.
- `receipt` is required at registration and is defensively copied and frozen
  before the transaction enters the registry or journal.
- `claim_reservation` and `resource_bindings` are either both omitted or both
  supplied. When supplied, the reservation must be pending under the exact
  active owner and the bindings must account for every reserved claim exactly
  once. Registration atomically consumes those claims into the transaction;
  foreign, released, consumed, duplicate, missing, or incompatible claims fail
  without partially registering the transaction and leave the reservation
  pending for correction or explicit release.
- Omitting both resource fields declares a resource-independent cleanup
  transaction. Such transactions participate in teardown but use LIFO ordering
  because they introduce no dependency-graph edges.
- The receipt identifies an effect that already exists. `registerCleanup()` is
  not a speculative reservation API; callers create or change the resource,
  then register its cleanup before yielding or publishing it to other test code.
- Receipts are bounded plain data containing stable IDs and immutable scalar
  baselines. They cannot contain native userdata, callbacks, cycles, or mutable
  tables shared with test code.
- `cleanup_timeout_ms`, when present, is a positive finite cleanup deadline
  override; otherwise the project cleanup setting and then the framework default
  apply. The separate trailing `command_options.timeout_ms` bounds the
  registration command itself.
- `restore` executes once. `verify` is read-only and retries under the cleanup
  deadline when it throws, returns `false`, or explicitly returns
  `cleanup.pending(...)`; a no-return assertion callback passes when it does not
  throw.
- `restore` and `verify` receive a restricted cleanup execution context plus the
  same immutable receipt. The receipt is their only transaction-specific data.
  Capturing required cleanup identity through closure variables is unsupported.
  The context exposes bounded time, cleanup cancellation, safe diagnostics, and
  read-only query/assertion execution during verification; mutable transaction
  state and journal mutation remain private to the engine. `restore` cannot
  invoke public commands or register more cleanup. `verify` may invoke only
  read-only public queries or assertions; they inherit the transaction's owner,
  fresh cleanup cancellation scope, and remaining cleanup deadline. Public
  mutations or cleanup registration from verification are contract errors.
- The runtime validates receipt shape and presence but does not attempt to
  inspect callback upvalues or prove that a callback uses no closure values.
  Correctness-critical stable identities, baselines, and operation keys are
  supported only through the receipt.
- A restore error does not suppress verification when time remains; both
  outcomes are retained and the transaction remains failed.
- The returned transaction can be executed manually at any later point in its
  owning suite or test lifecycle while it remains pending.
- Manual execution unregisters and expends the transaction before calling
  `restore` and `verify`; successful execution returns `true`, while repeated
  execution returns `false` without invoking them again.
- A manual failure is recorded with terminal `failed` disposition before its
  composed cleanup error is raised into the active suite or test lifecycle. It
  does not return `false` and is not silently retried during teardown.
- Manual execution does not transfer ownership. A suite-owned transaction
  invoked from a nested test remains attributed to the suite cleanup result,
  while the raised error is observed by the currently active test lifecycle.
- One callback failure does not suppress later cleanup entries.
- Registration performs no product or native mutation; its intended framework
  effect is creation of the cleanup transaction. The caller cannot discard a
  transaction without executing it.
- Test or suite teardown automatically executes every transaction that remains
  pending in dependency-safe reverse-topological order, using LIFO only to
  order independent transactions.

Example:

```lua
local registration_id = create_registration()
local cleanup = ds.registerCleanup{
    label='remove temporary native registration',
    receipt={registration_id=registration_id},
    restore=function(_context, receipt)
        remove_registration(receipt.registration_id)
    end,
    verify=function(_context, receipt)
        assert.is_false(registration_exists(receipt.registration_id))
    end,
}
publish_registration(registration_id)

-- Optional early cleanup; teardown would otherwise execute it automatically.
cleanup:execute('fixture no longer needed')
```

### `ds.spawnItem(options)`

```lua
---@class dwarfspec.SpawnItemOptions
---@field item_type df.item_type
---@field material string
---@field position dwarfspec.MapPosition
---@field subtype? integer|string
---@field quality? df.item_quality
---@field stack_size? integer
---@field creator_unit_id? integer

---@param options dwarfspec.SpawnItemOptions
---@return integer item_id
function ds.spawnItem(options) end
```

The command creates a new DwarfSpec-owned item at an exact valid map position.
It never searches for or borrows an existing item.

Contract:

- `item_type` and `quality` use canonical DF enums.
- `material` uses a canonical DFHack material token and must resolve before
  construction begins.
- Subtype validation is item-type aware. An absent required subtype is an error;
  an irrelevant subtype is also an error.
- Creature-derived items require an explicit `creator_unit_id` or another
  future type-specific field; the command does not silently select an organic
  unit.
- The return value is the stable native item ID.
- Cleanup removes jobs and references created because of the owned item, removes
  the item, and verifies that the ID and owned references are absent.
- Cleanup fails closed when an unrelated native object has taken ownership of
  the item in a way DwarfSpec cannot safely detach.

Example:

```lua
local item_id = ds.spawnItem{
    item_type=df.item_type.GLOVES,
    subtype=0,
    material='CREATURE:DWARF:LEATHER',
    position={x=100, y=100, z=20},
}
```

### `ds.createStockpile(options)`

```lua
---@class dwarfspec.CreateStockpileOptions
---@field tiles dwarfspec.MapPosition[]
---@field label? string

---@param options dwarfspec.CreateStockpileOptions
---@return integer building_id
function ds.createStockpile(options) end
```

The initial command creates only a stockpile building. It does not generalize to
arbitrary workshops, furniture, zones, or constructions.

Contract:

- `tiles` is nonempty, unique, same-z, in bounds, and representable by one
  native stockpile footprint.
- Every tile must already be reserved by this cleanup owner or must pass the same
  safety validation used by `ds.reserveMapTiles()` and become reserved
  atomically during creation.
- DwarfSpec creates the minimal native building footprint and exact room
  extents needed to cover the supplied tiles.
- The command returns the stable building ID.
- The initial API deliberately does not model the complete native stockpile
  filter schema. Tests may configure the returned building through native APIs.
- Cleanup removes native jobs owned because of the stockpile, deconstructs the
  stockpile, releases only tile reservations acquired atomically by this
  command, and verifies absence by ID and tile occupancy. A reservation that
  already existed when the command began remains owned by its original cleanup
  transaction.
- Cleanup does not delete unrelated items that later enter the stockpile.

Example:

```lua
local tiles = ds.reserveMapTiles{count=1}
local stockpile_id = ds.createStockpile{tiles=tiles}
```

### `ds.reserveMapTiles(options)`

```lua
---@enum dwarfspec.EMapTileArrangement
ds.EMapTileArrangement = {
    ANY=1,
    ADJACENT=2,
    RECTANGLE=3,
}

---@class dwarfspec.MapTileQueryFilterFlags
---@field floor? boolean
---@field empty? boolean
---@field exclude_buildings? boolean
---@field exclude_items? boolean
---@field exclude_units? boolean
---@field exclude_job_reservations? boolean

---@class dwarfspec.ReserveMapTilesOptions
---@field count integer
---@field arrangement? dwarfspec.EMapTileArrangement
---@field filters? dwarfspec.MapTileQueryFilterFlags
---@field reachable_from_unit_id? integer
---@field near? dwarfspec.MapPosition
---@field predicate? fun(position: dwarfspec.MapPosition): boolean

---@param options dwarfspec.ReserveMapTilesOptions
---@return dwarfspec.MapPosition[] positions
function ds.reserveMapTiles(options) end
```

Contract:

- The default arrangement is `ANY`.
- The default filters require valid, walkable floor with no building, item,
  unit, or native job reservation.
- For map-tile flags, `true` enables the named requirement and `false` disables
  it; unlike unit classification flags, `false` does not require the semantic
  opposite. Omitted fields inherit the safe defaults above.
- Candidate enumeration and the final result are deterministic.
- `ADJACENT` requires one connected orthogonal group.
- `RECTANGLE` requires an exact filled rectangle.
- `near` affects deterministic distance ordering but never weakens filters.
- `reachable_from_unit_id` requires native path reachability from the resolved
  unit.
- The optional predicate receives a copied scalar position after built-in
  filters.
- A reservation prevents overlap with every incompatible active reservation in
  the run-scoped `ResourceDependencyIndex`, including claims owned by an active
  suite and its nested test attempts. It is not a native lock and must be
  revalidated immediately before a later mutating command consumes it.
- Cleanup releases logical reservations and verifies that DwarfSpec retains no
  reservation records. It does not modify the map.

### `ds.spyJobs(options)`

```lua
---@param options dwarfspec.JobSpyOptions|nil
---@return luassert.spy job_spy
function ds.spyJobs(options) end
```

`ds.spyJobs()` installs a run-managed native job observer and returns a
Busted-compatible callable spy. DwarfSpec calls the spy once for each matching
lifecycle snapshot:

```lua
job_spy(snapshot)
```

This preserves familiar Busted assertions:

```lua
local job_spy = ds.spyJobs{
    job_type=df.job_type.DumpItem,
    item_ids={item_id},
}

trigger_native_work()

ds.await('dump job is observed', function()
    return #job_spy.calls > 0
end)
assert.spy(job_spy).was.called()
```

Contract:

- Observation is active before the command returns.
- `job_type`, when supplied, is a valid canonical `df.job_type` value.
- The predicate receives a live job only during synchronous matching. Its
  return value is combined with all declarative filters.
- Native callbacks and bounded reconciliation scans feed one deduplicated event
  stream. DwarfSpec must tolerate event-before-scan and removal-before-scan
  races.
- Each logical transition is delivered at most once for one `(job_id, event)`
  identity.
- Calls are ordered by DwarfSpec sequence number. Tick is diagnostic and is not
  assumed globally unique.
- The default event set contains every supported lifecycle event.
- Events that cannot be established reliably on a supported DFHack version are
  rejected during capability validation rather than silently omitted.
- Cleanup stops callbacks and recurring scans, releases retained snapshots, and
  verifies that no observer remains registered.
- The spy is observation-only. It does not claim, suspend, accelerate, cancel,
  or remove native jobs.

### `ds.queryUnits(options)`

```lua
---@param options dwarfspec.UnitQueryOptions|nil
---@return integer[] unit_ids
function ds.queryUnits(options) end
```

The command queries the loaded world's unit collection and returns matching
stable unit IDs.

Contract:

- With no options, the command returns every resolvable world unit ID.
- Built-in `filters` are evaluated before `predicate`.
- `exclude_ids` is normalized into a unique integer set.
- The predicate receives the live `df.unit` instance and returns a boolean.
- Predicate mutation is outside this command's contract; `queryUnits()` is a
  read-only operation and does not register cleanup for predicate side effects.
- Results are deduplicated and sorted by ascending unit ID.
- An empty match returns `{}`. It is not an assertion failure.
- A world transition invalidates prior meanings of IDs; callers must query
  again after loading or unloading a world.

Examples:

```lua
local citizens = ds.queryUnits{
    filters={
        active=true,
        alive=true,
        citizens=true,
        fort_controlled=true,
        animals=false,
    },
}

local commandable = ds.queryUnits{
    filters={active=true, alive=true},
    predicate=function(unit)
        return custom_policy_accepts(unit)
    end,
}

local pets = ds.queryUnits{
    filters={active=true, alive=true, pets=true},
}
```

### `ds.disableUnitsAi(unit_ids)`

```lua
---Temporarily suspends ordinary per-unit processing for selected units.
---@param unit_ids integer[]
function ds.disableUnitsAi(unit_ids) end
```

The command temporarily marks eligible units inactive through the native
`unit.flags1.inactive` bit. This is the same bit evaluated by
`dfhack.units.isActive(unit)`. It is a managed state transition, not a new
DFHack AI hook.

Contract:

- `unit_ids` is a nonempty dense array of unique integers. DwarfSpec resolves
  and validates every ID before registering ownership or changing any unit.
- Every target must be alive, on-map, currently active, and present exactly
  once in `df.global.world.units.active` in the loaded fortress world.
- A unit may be owned by at most one inactive-state transaction at a time.
  Overlap with another `disableUnitsAi()` call or `setUnitSpeed()` target
  ownership is rejected before mutation.
- DwarfSpec snapshots the complete validated target set and baseline first. It
  sets the first inactive flag, confirms that effect, and immediately registers
  verified cleanup whose receipt covers the complete target set before changing
  the next target. Restoration is idempotent for targets whose flag was never
  changed if a later write fails.
- The command sets only `unit.flags1.inactive`. It does not remove or reorder
  active-vector entries, cancel or replace jobs, clear actions, discard paths,
  change positions, or alter occupancy.
- While the flag remains set, the target unit's ordinary per-unit update is
  suspended. The qualified effect includes action-timer progress and the
  associated AI, movement, and pathfinding work that would be initiated by that
  update.
- Other native systems may still retain, inspect, target, collide with, or
  otherwise account for the unit. The command does not promise that global
  pathfinding or world simulation excludes every reference to it.
- `dfhack.units.isActive(unit)` returns `false` while ownership is active, so a
  concurrent `queryUnits{filters={active=true}}` excludes the target and
  `active=false` can include it.
- Cleanup resolves each stable unit ID in the same loaded world, clears the
  inactive bit, and verifies active classification plus exactly one unchanged
  active-vector membership.
- If a target disappears, changes world identity, leaves the map, dies, or
  otherwise reaches a state where clearing the bit would corrupt native
  lifecycle state, cleanup fails closed without forcing reactivation. The
  failed cleanup quarantines the executor under the shared contract.

Example:

```lua
local background_units = ds.queryUnits{
    filters={active=true, alive=true},
    exclude_ids={subject_unit_id},
}
ds.disableUnitsAi(background_units)

ds.runUntil('the subject reaches its destination', function()
    return subject_reached_destination()
end)
```

Feasibility evidence on DF 53.15-r2 established the native mechanism before
this command was proposed. With an organic unit action first shown to progress,
setting `unit.flags1.inactive=true` held its action timer, position, path,
current job, and action list unchanged across 60 unpaused game ticks while the
unit remained uniquely present in `world.units.active`. Clearing the flag
resumed action progress, and terminal DwarfSpec cleanup confirmed restoration.
This evidence establishes practical per-unit processing suspension; it does not
instrument or exclude unrelated global pathfinding consumers.

### `ds.runUntil(description, query, options, command_options)`

```lua
---@class dwarfspec.RunUntilOptions
---@field frame_budget? integer

---@param description string
---@param query fun(): any
---@param options? dwarfspec.RunUntilOptions
---@param command_options? dwarfspec.CommandOptions
---@return any result
function ds.runUntil(description, query, options, command_options) end
```

This command is the simulation-running counterpart to `ds.await()`.

Contract:

- Capture the current pause state before invoking the query.
- Unpause the game when necessary.
- Apply the same frame-budget, diagnostics, and query-result semantics as
  `ds.await()` while obtaining the wall-clock deadline from shared command
  options.
- Restore the captured pause state before returning or propagating an error.
- If pause-state restoration fails, preserve both the primary failure and the
  restoration failure.
- Do not alter TPS, turbo speed, or per-unit acceleration.
- Do not imply that native simulation is otherwise reversible.

Example:

```lua
local completed = ds.runUntil('native work completes', function()
    return native_work_is_complete()
end, {
    frame_budget=1200,
}, {
    timeout_ms=30000,
})
```

## Interactions between commands

### Items, stockpiles, and tile reservations

`spawnItem()` may consume a reserved tile but does not release that reservation;
the reservation remains valid until its owning suite or test cleanup.
`createStockpile()` records a dependency on every reservation that already
exists when the command begins; it neither transfers nor releases those
reservations. A reservation acquired atomically during stockpile creation is
instead owned by the stockpile transaction and is released by stockpile
cleanup. `ResourceDependencyIndex` rejects release of a pre-existing
reservation while its stockpile claim remains active. Cleanup removes dependent
owned jobs before removing items or stockpiles and releases atomically acquired
logical reservations last.

`ResourceDependencyIndex` must not infer ownership merely because an object
occupies a reserved tile. Only explicit claims established by fixture commands
are owned. Claims are tagged by owner, and consumption, sharing, or dependency
across suite, test, command, or service-run levels requires an explicit domain
relationship rather than being inferred from lifecycle nesting.

### Job spies and accelerated simulation

`spyJobs()` is installed before the mutation that triggers native work. Tests
may then use `setGameSpeed()`, `setUnitSpeed()`, or `runUntil()` without losing a
short-lived creation or assignment boundary. The spy records observation only;
acceleration commands retain their existing independent cleanup behavior.

### Inactive units and continuing simulation

`disableUnitsAi()` can be composed with `runUntil()` to keep selected background
units suspended while other native work advances. The unit IDs are snapshotted
at command preflight; units that later become eligible are not added
automatically.

Inactive-state ownership and targeted unit-speed ownership are mutually
exclusive for the same unit. This avoids a recurring acceleration operation
competing with inactive-state suspension. Job spies remain global observers and
may still observe lifecycle changes caused by systems other than the inactive
unit.

### Public and automatic cleanup

Fixture commands register private cleanup entries through the same internal
`CleanupRegistrationService` used by the public `registerCleanup()` command.
Private entries may use stronger internal
identity metadata, but they obey the same ordering, aggregation, verification,
and reporting rules as public entries. Every public or private registration is
attributed to its owning suite execution or test attempt and appears in that
owner's cleanup transaction result set even after it has been manually
expended.

## Architecture

The implementation should preserve DwarfSpec's existing ownership boundaries:

- `dwarfspec.driver.commands` exposes command definitions and domain-specific
  validation through the shared command runner.
- Native unit, item, building, map, and job behavior lives in focused driver
  adapters or controllers.
- The run's suite-execution and test-attempt contexts own isolated cleanup
  registries and cleanup execution indexes.
- One run-scoped `ResourceDependencyIndex` tracks owner-tagged resource claims,
  logical tile reservations, active job spies, inactive-unit flag transitions,
  cleanup linkage, compatible sharing, and exclusive conflicts across
  service-run, suite-execution, test-attempt, and command-invocation levels. Its
  prerequisite `DirectedAcyclicGraph` supplies generic graph behavior.
  `ResourceDependencyIndex` owns lifetime validation and resource
  policy. `CleanupPlanner` produces deterministic reverse-topological cleanup
  plans for every command family.
- Closed DwarfSpec discriminators live in protocol enum modules as immutable
  numeric tables.
- Canonical DF discriminators such as `df.item_type`, `df.item_quality`, and
  `df.job_type` are accepted directly and are not duplicated in protocol enums.
- `ds.lua` remains a composition facade rather than accumulating native fixture
  algorithms.
- `ds.d.lua` declares every public option, result, enum, callback, and command.

Dependencies should remain capability-injected so request validation,
selection, ownership, cleanup ordering, and observer reconciliation can be unit
tested without a live world.

## Validation strategy

The command-engine and risk-based checkpoint strategy in
`verified-command-execution-proposal.md` governs execution. The requirements
below describe the eventual domain evidence, not an instruction to rerun full
live and package qualification after every small implementation change.

### Unit coverage

Each command requires unit tests for:

- argument validation before mutation;
- deterministic normalization and ordering;
- canonical enum acceptance and invalid-enum rejection;
- callback and predicate error preservation;
- rejection of cleanup registration without a verification callback;
- required cleanup receipt validation and freezing, identical receipt delivery
  to restore and verification, and no claim that callback closure semantics can
  be enforced;
- cleanup registration immediately after a conclusive effect receipt and before
  later fallible work, yielding, verification, retry, or publication;
- caller resource-claim reservation before mutation, owner-bound reservation
  handles, exact/provisional binding, atomic all-claim consumption into
  `registerCleanup`, explicit no-effect release, and automatic release of unused
  reservations before owner cleanup;
- structured partial-effect failure receipts and rejection of adapters that can
  mutate before throwing without reporting a cleanup identity;
- verified cleanup of every effect created by a retry attempt before another
  attempt may execute;
- reverse-topological cleanup, LIFO ordering of independent transactions, and
  continued cleanup after failure, including `dependency_blocked` failure for
  prerequisites that cannot safely execute after dependent cleanup fails;
- idempotent cleanup transaction execution;
- finite cleanup timeout precedence, one-shot restore, retryable verification,
  restore-error verification, and deadline expiry;
- complete authoritative journal retention after manual and teardown
  execution;
- stable suite/test owner and owning-command attribution;
- isolation between suite executions, neighboring tests, and repeats;
- cross-level resource-claim conflict detection, explicit sharing and
  dependency relationships, reusable DAG cycle and lifetime-direction
  validation, reverse-topological cleanup with LIFO tie-breaking, rejection of
  prerequisite release while dependent claims remain active, and claim
  retention after failed or unconfirmed cleanup;
- suite-owned registration during setup and teardown, manual suite-transaction
  expenditure from a nested test without ownership transfer, and automatic
  suite cleanup after setup failure or zero executed tests;
- one terminal transaction disposition in both the service journal and
  persisted result;
- `unconfirmed` reporting when interruption prevents terminal verification;
- cleanup callback command restrictions and inherited deadlines for read-only
  queries or assertions used during cleanup verification;
- rejection of duplicate, missing, or journal-inconsistent transaction result
  records;
- verification failure aggregation; and
- declaration/runtime signature agreement.

`queryUnits()` additionally requires a truth table for every
`UnitQueryFilterFlags` field, including overlapping `pets` and `animals`
classifications, exclusion IDs, predicate ordering, empty results, and stable
sorting.

`disableUnitsAi()` additionally requires dense and duplicate-ID validation,
  all-target preflight before mutation, active-vector uniqueness checks,
  registration immediately after the first confirmed flag write and before the
  next write, overlapping-ownership rejection, flag-only mutation, stable-ID
  cleanup, fail-closed terminal-state handling, and
verification that cleanup restores active classification without duplicating or
reordering active-vector entries.

`createStockpile()` additionally requires coverage that pre-existing tile
reservations remain owned by their original transactions, atomically acquired
reservations belong to stockpile cleanup, and an active stockpile dependency
prevents premature reservation release.

`spyJobs()` additionally requires event-before-scan, scan-before-event,
removal-before-scan, repeated callback, job-ID reuse defense, filter
intersection, canonical `df.job_type` validation, Busted assertion
compatibility, and observer cleanup coverage.

### Live qualification

Focused live tests should prove:

- an owned item is created, resolved by ID, removed, and verified absent;
- an owned stockpile is constructed on reserved tiles and leaves no building or
  native job behind;
- overlapping tile reservations are rejected deterministically;
- unit queries return stable IDs and apply live predicates correctly;
- an organic unit action progresses while active, remains unchanged with its
  position, path, job, action list, and active-vector membership across a
  bounded inactive window, and resumes after verified reactivation;
- a job spy observes a short-lived job while game and unit speed are elevated;
- `runUntil()` restores both initially paused and initially unpaused states;
- deliberate body failure still drains and verifies all owned resources; and
- deliberate cleanup failure produces `cleanup_confirmed=false` and executor
  quarantine.

The final live report must be terminal and must include cleanup confirmation.
Passing assertions without verified cleanup are insufficient.

## Delivery order

1. Implement and qualify the
   [directed acyclic graph utility proposal](directed-acyclic-graph-proposal.md).
2. Expose `reserveResourceClaims()`, `registerCleanup()`, the run-scoped
   `ResourceDependencyIndex`, its graph instance and `CleanupPlanner`, and the
   cleanup history/result-journal integration
   defined by the verified command execution proposal.
3. Add `reserveMapTiles()` and `queryUnits()` as read-mostly discovery
   primitives.
4. Add `disableUnitsAi()` with flag-only ownership and fail-closed verified
   restoration.
5. Add `spawnItem()` with complete ownership and removal verification.
6. Add `createStockpile()` on top of tile reservations and
   `ResourceDependencyIndex`.
7. Add `spyJobs()` with Busted compatibility and reconciled native observation.
8. Add `runUntil()` as a pause-safe composition over `await()`.

Every command must have declarations, focused domain coverage, documentation,
and the live evidence required by its native risk. Full package and family live
qualification occur at the integration checkpoints defined by the verified
command execution proposal rather than unconditionally before work begins on
the next command.

## Deferred extensions

- Additional unit classifications such as residents, visitors, invaders,
  adults, sane units, or idle units may be added to `UnitQueryFilterFlags` when
  their canonical semantics are agreed.
- Multiple accepted job types may later be exposed as `job_types`, but the
  initial `job_type` field remains one canonical `df.job_type` value.
- Additional item-family constructors may extend `SpawnItemOptions` through
  explicit typed variants rather than ambiguous optional fields.
- Stockpile filter configuration may receive a separate typed command after the
  native settings schema has its own proposal and compatibility strategy.
- A general managed-building API remains out of scope until several concrete
  building commands establish shared lifecycle semantics.
