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

The proposed public entry points are:

```lua
ds.registerCleanup(options)
ds.spawnItem(options)
ds.createStockpile(options)
ds.reserveMapTiles(options)
ds.spyJobs(options)
ds.queryUnits(options)
ds.runUntil(description, query, options)
```

## Accepted direction

- Every mutating fixture command is example-scoped and registers cleanup before
  the created resource can become visible to test code or native simulation.
- Cleanup participates in DwarfSpec's existing LIFO cleanup, verification,
  reporting, and executor-quarantine behavior.
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
- Generalizing the initial stockpile command into arbitrary building
  construction.

## Shared lifecycle contract

### Scope and preconditions

All commands in this proposal execute inside the in-process DwarfSpec test
environment. World-dependent commands require a loaded fortress map and fail
before mutation if their preconditions are not met.

Each example receives an ownership ledger shared by these commands. The ledger
records stable resource identities, logical tile reservations, spies, and
project-registered cleanup entries. Example completion drains this ledger in
strict LIFO order.

### Register before publication

A mutating command must establish a cleanup record before publishing a resource
to the world or returning its identity. When the native API cannot separate
allocation from publication, the command must use a guarded transaction:

1. validate and normalize the complete request;
2. reserve cleanup capacity with a pending ownership record;
3. perform native construction;
4. attach the stable identity to the pending record;
5. verify the constructed resource;
6. return the identity.

If construction fails after native allocation, the pending cleanup record owns
the partial resource and teardown still runs.

### Cleanup and verification

Cleanup entries are idempotent and continue after individual failures. Each
entry has a restore or removal action followed by an independent verification
action. All failures retain their cleanup label and are aggregated into the
example result.

`cleanup_confirmed=true` is emitted only after:

- every cleanup-requiring entry was attempted, while any exceptional internal
  reservation was safely abandoned before mutation or publication;
- every entry-specific verification passed;
- every job spy and recurring observer was stopped;
- every logical map reservation was released; and
- DwarfSpec's existing lifecycle probes also passed.

An unverified or partially failed cleanup quarantines the executor under the
existing recovery contract.

Cleanup registration also publishes an append-only historical transition for
the owning test attempt into the authoritative run-scoped service journal.
Manual execution or teardown removes the transaction from that attempt's active
LIFO registry before callbacks run, but it does not remove its journal history.
The transaction reaches `complete`, `failed`, `abandoned`, or `unconfirmed` and
remains available through attempt-tagged journal events and the service-
materialized test result at
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

### `ds.registerCleanup(options)`

```lua
---@class dwarfspec.CleanupRegistration
---@field label string
---@field restore fun()
---@field verify fun(): boolean|dwarfspec.GateResult|nil
---@field timeout_ms? integer

---@class dwarfspec.CleanupTransaction
local CleanupTransaction = {}

---Executes and unregisters this transaction when it is still pending.
---@param reason? string
---@return boolean executed
function CleanupTransaction:execute(reason) end

---Returns whether this transaction remains registered for teardown.
---@return boolean
function CleanupTransaction:isPending() end

---@param options dwarfspec.CleanupRegistration
---@return dwarfspec.CleanupTransaction
function ds.registerCleanup(options) end
```

This command exposes DwarfSpec's existing cleanup registry to live specs. It is
the foundational command for project-defined native fixtures.

Contract:

- `label` is nonempty and appears in cleanup diagnostics.
- `restore` and `verify` execute in the same isolated test environment in which
  they were registered.
- Registration fails after example cleanup begins.
- `verify` is required so the transaction can contribute authoritative evidence
  to `cleanup_confirmed`.
- `timeout_ms`, when present, is a positive finite cleanup deadline override;
  otherwise the project cleanup setting and then the framework default apply.
- `restore` executes once. `verify` is read-only and retries under the cleanup
  deadline when it throws, returns `false`, or explicitly returns
  `cleanup.pending(...)`; a no-return assertion callback passes when it does not
  throw.
- A restore error does not suppress verification when time remains; both
  outcomes are retained and the transaction remains failed.
- The returned transaction can be executed manually at any later point in the
  test while it remains pending.
- Manual execution unregisters and expends the transaction before calling
  `restore` and `verify`; repeated execution does not invoke them again.
- A manual failure is recorded in cleanup evidence and propagates to the test.
- One callback failure does not suppress later cleanup entries.
- Registration itself performs no mutation. The caller cannot discard a
  transaction without executing it.
- Test teardown automatically executes every transaction that remains pending
  in strict LIFO order.

Example:

```lua
local cleanup = ds.registerCleanup{
    label='remove temporary native registration',
    restore=function()
        remove_registration()
    end,
    verify=function()
        assert.is_false(registration_exists())
    end,
}
publish_registration()

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
- Every tile must already be reserved by this example or must pass the same
  safety validation used by `ds.reserveMapTiles()` and become reserved
  atomically during creation.
- DwarfSpec creates the minimal native building footprint and exact room
  extents needed to cover the supplied tiles.
- The command returns the stable building ID.
- The initial API deliberately does not model the complete native stockpile
  filter schema. Tests may configure the returned building through native APIs.
- Cleanup removes native jobs owned because of the stockpile, deconstructs the
  stockpile, releases its tile reservations, and verifies absence by ID and tile
  occupancy.
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
- A reservation prevents overlap only among DwarfSpec commands in the same
  example. It is not a native lock and must be revalidated immediately before a
  later mutating command consumes it.
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
the reservation remains valid until example cleanup. `createStockpile()` may
consume one or more reservations and records their relationship in the
ownership ledger. Cleanup removes dependent owned jobs before removing items or
stockpiles and releases logical reservations last.

The ownership ledger must not infer ownership merely because an object occupies
a reserved tile. Only identities returned by successful fixture commands are
owned.

### Job spies and accelerated simulation

`spyJobs()` is installed before the mutation that triggers native work. Tests
may then use `setGameSpeed()`, `setUnitSpeed()`, or `runUntil()` without losing a
short-lived creation or assignment boundary. The spy records observation only;
acceleration commands retain their existing independent cleanup behavior.

### Public and automatic cleanup

Fixture commands register private cleanup entries through the same registry
exposed by `registerCleanup()`. Private entries may use stronger internal
identity metadata, but they obey the same ordering, aggregation, verification,
and reporting rules as public entries. Every public or private registration is
attributed to its owning test attempt and appears in that attempt's cleanup
transaction result set even after it has been manually expended.

## Architecture

The implementation should preserve DwarfSpec's existing ownership boundaries:

- `dwarfspec.driver.commands` exposes command definitions and domain-specific
  validation through the shared command runner.
- Native unit, item, building, map, and job behavior lives in focused driver
  adapters or controllers.
- The run/example context owns the cleanup registry, ownership ledger, logical
  tile reservations, and active job spies.
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
- cleanup registration before publication;
- LIFO cleanup and continued cleanup after failure;
- idempotent cleanup transaction execution;
- finite cleanup timeout precedence, one-shot restore, retryable verification,
  restore-error verification, and deadline expiry;
- complete authoritative journal retention after manual and teardown
  execution;
- stable test-attempt and owning-command attribution;
- isolation between neighboring tests and repeated attempts;
- one terminal transaction disposition in both the service journal and
  persisted result;
- `unconfirmed` reporting when interruption prevents terminal verification;
- rejection of duplicate, missing, or journal-inconsistent transaction result
  records;
- verification failure aggregation; and
- declaration/runtime signature agreement.

`queryUnits()` additionally requires a truth table for every
`UnitQueryFilterFlags` field, including overlapping `pets` and `animals`
classifications, exclusion IDs, predicate ordering, empty results, and stable
sorting.

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
- a job spy observes a short-lived job while game and unit speed are elevated;
- `runUntil()` restores both initially paused and initially unpaused states;
- deliberate body failure still drains and verifies all owned resources; and
- deliberate cleanup failure produces `cleanup_confirmed=false` and executor
  quarantine.

The final live report must be terminal and must include cleanup confirmation.
Passing assertions without verified cleanup are insufficient.

## Delivery order

1. Expose `registerCleanup()`, the example ownership ledger, and the cleanup
   history/result-journal integration defined by the verified command execution
   proposal.
2. Add `reserveMapTiles()` and `queryUnits()` as read-mostly discovery
   primitives.
3. Add `spawnItem()` with complete ownership and removal verification.
4. Add `createStockpile()` on top of tile reservations and the ownership ledger.
5. Add `spyJobs()` with Busted compatibility and reconciled native observation.
6. Add `runUntil()` as a pause-safe composition over `await()`.

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
