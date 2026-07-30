# Managed world mounting proposal

## Status

This document is an exploratory design proposal for a future managed-world
fixture system. It records the current agreements, identifies unresolved
contracts, and separates the feature into independently refinable workstreams.
It is not an implementation checklist and does not describe shipped DwarfSpec
behavior.

The proposed entry point is:

```lua
ds.mountWorld(name, config)
```

The system would provision, load, reuse, and restore DwarfSpec-owned worlds for
live tests. Provisioning includes world generation, deterministic embark-site
selection, entering fortress mode, making an initial save, and capturing a
pristine baseline.

Related documents:

- [`save-game-mount.todo`](save-game-mount.todo) specifies the narrower
  `ds.mountSaveGame(directory_name)` transition command.
- [`testbed-evaluation.md`](testbed-evaluation.md) describes Lua module-graph
  isolation. A managed world complements that isolation; it does not replace
  it.
- [`architecture.md`](architecture.md) describes the existing DwarfSpec host,
  scheduler, cleanup, and command boundaries.

## Accepted direction

The following decisions are accepted unless later discussion revises them:

- The public entry point is `ds.mountWorld(name, config)`.
- `name` is a logical fixture name, not a save-directory name or filesystem
  path.
- `WorldConfig` separates immutable fixture definition from per-test isolation
  requirements.
- `WorldDefinition` contains a `MapDefinition` describing the desired embark
  map.
- The default generated world is deliberately small.
- The default embark rectangle is 2 by 2 local embark tiles.
- The world-generation master seed defaults to `0` for repeatability.
- The string `"random"` requests random generation during initial
  provisioning.
- A random fixture records its resolved native seeds and reuses the realized
  world on later mounts.
- A test that does not declare its isolation behavior conservatively requires
  a pristine world and leaves the entire world dirty.
- Reuse is an optimization. Uncertain state must cause restoration or a
  bounded failure, never optimistic reuse.
- DwarfSpec must never discard, overwrite, or silently save an unmanaged
  player world.

## Goals

- Let a test request a named, strongly defined world fixture.
- Provision a missing fixture without manual world generation or embark.
- Make the common fixture small enough for practical live-test iteration.
- Reuse an already loaded compatible fixture without unnecessary unloading or
  loading.
- Restore an immutable baseline when a test requires state that an earlier
  test may have changed.
- Make generation and site selection repeatable by default.
- Preserve the realized seeds and site selection for diagnostics.
- Fail safely when configuration, ownership, or current-game state is
  ambiguous.
- Keep world-state isolation distinct from Lua, plugin, input, screen,
  filesystem, and process isolation.
- Provide enough diagnostics to explain why a fixture was generated, loaded,
  restored, or reused.
- Leave room for more than one provisioning backend without exposing
  backend-specific behavior to test authors.

## Non-goals

- Providing a complete snapshot or diff of every mutable Dwarf Fortress field.
- Detecting arbitrary mutations performed by test or plugin code.
- Treating a world reload as process isolation.
- Restoring plugin globals, Lua module state, external files, DF preferences,
  or unmanaged event registrations through the world-fixture mechanism.
- Accepting arbitrary save paths from test code.
- Managing ordinary player saves.
- Running two simultaneous world transitions.
- Supporting multiple loaded worlds in one Dwarf Fortress process.
- Guaranteeing that every possible site-constraint combination can be
  generated.
- Silently relaxing requested generation or embark constraints.
- Making the optional external `-gen` process the only provisioning path.
- Defining detailed starting-party customization in the initial contract.

## Terminology

- **Logical fixture name:** The project-facing name passed to
  `ds.mountWorld()`, such as `"stockpile-fixture"`. It is mapped to
  DwarfSpec-owned storage through a manifest.
- **Definition:** The immutable requested properties used to identify a
  fixture. Generation, embark-map, and initial-embark settings belong to the
  definition.
- **Realization:** The concrete generated world associated with a definition.
  It includes the four native Dwarf Fortress seeds, world identity,
  civilization, site, local embark rectangle, and save directory.
- **Working save:** The save directory Dwarf Fortress loads and may mutate
  while tests execute.
- **Pristine baseline:** An immutable whole-save snapshot made immediately
  after a successful initial embark and durable save.
- **Facet:** A coarse category of world state used to decide whether a working
  world is compatible with a later test.
- **Dirty ledger:** The set of facets that may differ from the pristine
  baseline.
- **Managed world:** A world whose manifest, ownership marker, definition,
  realization, working save, and baseline have all been verified by
  DwarfSpec.
- **Unmanaged world:** Any loaded or stored world that DwarfSpec cannot prove
  it owns.

## Proposed public API

### Basic deterministic fixture

```lua
local world = ds.mountWorld('default-fixture')

assert.equals('default-fixture', world.name)
assert.equals(2, world.map.size.width)
assert.equals(2, world.map.size.height)
```

Omitting `config` uses the complete default definition and conservative
isolation policy.

### Defined fixture

```lua
---@type dwarfspec.WorldConfig
local config = {
    definition={
        generation={
            seed=0,
            world_size='pocket',
            history_years=2,
        },
        map={
            size={
                width=2,
                height=2,
            },
            site={
                aquifer='none',
                flux=true,
            },
        },
        embark={
            mode='quickstart',
        },
    },
    isolation={
        reads={
            'map_tiles',
            'units',
            'items',
        },
        writes={
            'jobs_orders',
            'items',
        },
    },
}

local world = ds.mountWorld('stockpile-fixture', config)
```

### Random initial generation

```lua
local world = ds.mountWorld('exploratory-fixture', {
    definition={
        generation={
            seed='random',
        },
    },
})
```

`"random"` means random when the fixture is first provisioned. It does not
mean random on every mount. The manifest stores the resolved seeds, and later
mounts reuse the same realization until the fixture is explicitly recreated.

### Proposed authoring-time types

The exact field set remains open to refinement. The authoritative production
annotations and `ds.d.lua` declarations must eventually use one canonical set
of types rather than parallel copies.

```lua
---Selects the requested master-seed behavior for world generation.
---@alias dwarfspec.WorldSeed integer|'"random"'

---Selects the generated world's region dimensions.
---@alias dwarfspec.WorldSize
---| '"pocket"'
---| '"smaller"'
---| '"small"'
---| '"medium"'
---| '"large"'

---Selects an embark aquifer requirement.
---@alias dwarfspec.AquiferRequirement
---| '"any"'
---| '"none"'
---| '"light"'
---| '"heavy"'
---| '"light_or_none"'

---Identifies one coarse category of mutable world state.
---@alias dwarfspec.WorldFacet
---| '"all"'
---| '"calendar_weather"'
---| '"map_tiles"'
---| '"units"'
---| '"items"'
---| '"buildings_zones"'
---| '"jobs_orders"'
---| '"fortress_state"'
---| '"world_history"'
---| '"site_persistence"'
---| '"unknown_native"'

---Reports how a requested fixture reached its mounted state.
---@alias dwarfspec.WorldMountAction
---| '"generated"'
---| '"loaded"'
---| '"restored"'
---| '"reused"'

---Defines the size of a local embark rectangle.
---@class dwarfspec.MapSize
---@field width? integer Defaults to 2.
---@field height? integer Defaults to 2.

---Defines criteria used to select a valid embark site.
---@class dwarfspec.EmbarkSiteCriteria
---@field aquifer? dwarfspec.AquiferRequirement Defaults to `"any"`.
---@field flux? boolean
---@field clay? boolean
---@field sand? boolean
---@field soil_minimum? integer
---@field river_minimum? string
---@field savagery? string
---@field evilness? string
---@field biome_count_minimum? integer
---@field neighbors? string[]

---Selects one exact embark location when discovery is not desired.
---@class dwarfspec.ExactEmbarkLocation
---@field region_x integer
---@field region_y integer
---@field local_x integer
---@field local_y integer

---Defines the playable map created by embarking.
---@class dwarfspec.MapDefinition
---@field size? dwarfspec.MapSize Defaults to a 2 by 2 embark rectangle.
---@field site? dwarfspec.EmbarkSiteCriteria
---@field location? dwarfspec.ExactEmbarkLocation Overrides site discovery.

---Defines the generated world that will contain the embark site.
---@class dwarfspec.WorldGenerationDefinition
---@field seed? dwarfspec.WorldSeed Defaults to `0`.
---@field world_size? dwarfspec.WorldSize Defaults to `"pocket"`.
---@field history_years? integer Defaults to 2.
---@field playable_civilization_required? boolean Defaults to true.

---Defines initial fortress setup after a site has been selected.
---@class dwarfspec.EmbarkDefinition
---@field mode? '"quickstart"' Defaults to `"quickstart"`.
---@field profile? string Reserved for a later starting-profile contract.

---Defines the immutable properties of one managed world fixture.
---@class dwarfspec.WorldDefinition
---@field generation? dwarfspec.WorldGenerationDefinition
---@field map? dwarfspec.MapDefinition
---@field embark? dwarfspec.EmbarkDefinition

---Declares the pristine state required and possible mutations for one test.
---@class dwarfspec.WorldIsolation
---@field reads? dwarfspec.WorldFacet[] Defaults to `{"all"}`.
---@field writes? dwarfspec.WorldFacet[] Defaults to `{"all"}`.

---Configures one managed-world request.
---@class dwarfspec.WorldConfig
---@field definition? dwarfspec.WorldDefinition
---@field isolation? dwarfspec.WorldIsolation

---Records the four native seeds resolved from one requested master seed.
---@class dwarfspec.ResolvedWorldSeeds
---@field world string
---@field history string
---@field name string
---@field creature string

---Records the realized playable map.
---@class dwarfspec.ResolvedMap
---@field size dwarfspec.MapSize
---@field location dwarfspec.ExactEmbarkLocation
---@field civilization_id integer

---Describes the mounted realization of one managed fixture.
---@class dwarfspec.WorldMount
---@field name string
---@field save_directory string
---@field definition_fingerprint string
---@field action dwarfspec.WorldMountAction
---@field seeds dwarfspec.ResolvedWorldSeeds
---@field map dwarfspec.ResolvedMap

---Mounts a managed world fixture for the current example.
---@param name string
---@param config? dwarfspec.WorldConfig
---@return dwarfspec.WorldMount
function DS.mountWorld(name, config) end
```

The criteria fields above are an initial vocabulary, not an accepted complete
surface. Each accepted criterion will need a precise type, normalization rule,
default, matching definition, diagnostic rendering, and live feasibility
proof.

## Default definition

The normalized default definition is provisionally:

```lua
{
    generation={
        seed=0,
        world_size='pocket',
        history_years=2,
        playable_civilization_required=true,
    },
    map={
        size={
            width=2,
            height=2,
        },
        site={},
    },
    embark={
        mode='quickstart',
    },
}
```

These defaults optimize for repeatability and provisioning speed:

- A pocket world is 17 by 17 region tiles.
- A history end year of 2 is the current minimum supported by advanced world
  generation.
- A 2 by 2 embark contains 96 by 96 playable map tiles because each local
  embark tile is 48 by 48 game tiles.
- Quickstart avoids detailed starting-party preparation.
- Requiring a playable civilization rejects worlds that cannot provide a
  fortress-mode embark.

The default definition does not require flux, soil, a river, a particular
biome, or the absence of aquifers. Such constraints can make a tiny world
substantially harder or impossible to provision and should be explicit.

References:

- [Dwarf Fortress world generation](https://dwarffortresswiki.org/index.php/World_generation)
- [Dwarf Fortress advanced world generation](https://dwarffortresswiki.org/index.php/Advanced_world_generation)
- [Dwarf Fortress embark](https://dwarffortresswiki.org/index.php/Embark)

## Master-seed semantics

Dwarf Fortress uses distinct world, history, name, and creature seeds. The
public proposal intentionally exposes one master seed for the common case.

For an integer master seed:

1. Normalize the integer to one canonical textual representation.
2. Derive four native seeds with a stable, domain-separated algorithm.
3. Write every resolved seed explicitly into the generation parameters.
4. Record the derivation version and four results in the manifest.

For example, the conceptual derivation inputs are:

```text
<algorithm-version>:world:<master-seed>
<algorithm-version>:history:<master-seed>
<algorithm-version>:name:<master-seed>
<algorithm-version>:creature:<master-seed>
```

The final hash and numeric encoding remain an implementation decision. They
must be stable across supported Lua hosts and must not depend on table order,
process-specific hashing, locale, or native integer overflow.

For `"random"`:

1. Generate four native seeds during initial provisioning.
2. Store them before beginning destructive or lengthy generation work.
3. Use the stored values for retry and recovery of that provisioning
   transaction.
4. Preserve them in the completed manifest.
5. Reuse them whenever the fixture is loaded again.

A `"random"` requested definition therefore has two identities:

- a requested-definition fingerprint containing the random seed mode; and
- a realized fingerprint containing the resolved native seeds.

Explicit fixture recreation produces a new realization. Ordinary mounting does
not.

Lua cannot distinguish an omitted table field from a field explicitly assigned
`nil`. That is why the public random value is `"random"` while an omitted
`seed` receives the default `0`.

## Definition normalization and identity

Before consulting storage or changing game state, `ds.mountWorld()` should:

1. Validate the logical name and configuration types.
2. Apply all documented defaults.
3. Canonicalize maps, arrays, enums, integers, and absent optional fields.
4. Reject unknown fields unless the compatibility policy later permits them.
5. Compute a requested-definition fingerprint.

The fingerprint should include at least:

- managed-world schema version;
- seed mode and deterministic master seed when applicable;
- seed-derivation algorithm version;
- normalized generation settings;
- normalized map size and site criteria;
- normalized embark settings;
- Dwarf Fortress save compatibility version;
- DFHack compatibility version where transition behavior requires it;
- ordered raw and mod identity;
- provisioning-backend contract version.

The per-test isolation declaration must not participate in fixture identity.
Two tests can use the same realization while declaring different required and
mutated facets.

When a logical name already exists:

- an identical requested definition may reuse its realization;
- a different requested definition must fail with a bounded definition diff;
- DwarfSpec must not silently regenerate or replace the existing fixture;
- explicit recreation should be a separate administrative operation, not an
  option on ordinary `mountWorld()`.

## Manifest and storage model

The exact root remains open, but managed fixture storage should be scoped by
consumer project and should remain separate from arbitrary player saves.

One fixture conceptually contains:

```text
<fixture-root>/
  manifest.json
  operation-journal.json
  baseline/
    <whole save directory>
  working/
    <whole save directory or mapping metadata>
```

Dwarf Fortress ultimately needs the working save beneath its active save root.
The manifest must map the logical fixture name to that concrete directory
without exposing directory selection through the public API.

The manifest should record:

- logical fixture name;
- requested definition and fingerprint;
- realized definition and fingerprint;
- four resolved native seeds;
- generated world identity;
- selected civilization;
- region and local embark coordinates;
- embark rectangle;
- managed working-save directory;
- baseline identity and integrity information;
- Dwarf Fortress and DFHack compatibility information;
- current dirty ledger;
- last completed operation;
- clean-shutdown or interrupted-operation state.

The ownership marker must be independently verifiable from both the external
manifest and the managed save. A matching directory name alone is not proof of
ownership.

Whole save directories must be restored by replacement, never by merging
baseline files over a possibly dirty directory. Residual files from a later
save can otherwise survive and corrupt the restored state.

All renames, copies, and removals need:

- resolved absolute paths;
- containment beneath the selected managed root;
- verified ownership;
- an operation journal written before destructive work;
- bounded recovery on interruption;
- post-operation validation.

## Relationship to `ds.mountSaveGame()`

The planned `ds.mountSaveGame(directory_name)` command has example-scoped
ownership:

- it borrows a requested save that was already loaded;
- it owns a transition to a different requested save;
- example cleanup discards that target and restores the inherited save or
  title state.

Managed-world reuse has a different lifecycle:

- a fixture can remain loaded after one example finishes;
- example cleanup records the fixture's declared writes;
- a compatible later example can reuse the in-memory world;
- run cleanup, an incompatible request, or recovery may unload it.

Consequently, `ds.mountWorld()` must not be implemented as a simple public call
to `ds.mountSaveGame()`. The two features should share private, tested
transition machinery for:

- current-world identification;
- discard and unload;
- title/load-screen navigation;
- exact active-save selection;
- raw-frame waiting;
- state-change observation;
- timeouts and diagnostics;
- ownership verification;
- rollback and quarantine.

The existing save-game checklist remains authoritative for the narrower public
command. This proposal may eventually create new implementation dependencies
or amendments, but it does not retroactively alter that checklist.

## World-mount lifecycle

### Mount preflight

Before a transition, the command should:

- require a nonempty safe logical name;
- normalize and fingerprint the definition;
- normalize isolation independently;
- acquire the one process-wide world-transition lease;
- inspect current world, map, viewscreen, and managed ownership;
- reject incompatible example-owned stateful resources;
- reject an unmanaged loaded world;
- inspect the fixture manifest, journal, baseline, and working-save status;
- choose one explicit mount action.

The initial contract should require `mountWorld()` to be the first stateful
DwarfSpec operation in an example. This protects LIFO cleanup and prevents
subjects, screens, pointers, or other world-bound handles from surviving a
world transition.

### Mount action

| Current state | Requested state | Action |
|---|---|---|
| Same managed realization loaded and compatible | Existing fixture | Reuse |
| Same managed realization loaded but incompatible | Existing fixture | Discard, restore baseline if needed, and reload |
| Different managed realization loaded | Existing fixture | Discard current managed world and load target |
| No world loaded | Existing pristine fixture | Load target |
| No completed fixture exists | Valid missing fixture | Provision, save, snapshot, and mount |
| Incomplete operation exists | Recoverable fixture | Recover, then reevaluate |
| Unmanaged world loaded | Any fixture | Refuse without changing it |
| Definition fingerprint differs | Existing logical name | Refuse with a definition diff |

### Example cleanup

Cleanup should occur after all stateful resources created after the world mount
have been released.

World cleanup should:

- verify that the expected managed realization is still loaded;
- fail safely if an unrelated world appeared;
- union the normalized declared writes into the dirty ledger;
- persist the ledger before reporting cleanup success when persistence is part
  of the accepted design;
- release the example's fixture claim;
- leave the compatible managed world loaded for possible reuse;
- preserve `cleanup_confirmed=false` when ownership or ledger persistence
  cannot be proven.

Unlike component mounting, successful world-mount cleanup does not normally
unload the mounted resource.

### Run cleanup

The final run-state policy remains open. The safety-oriented candidate is:

- if the run inherited title state, discard the managed fixture and return to
  title;
- if it inherited the same managed fixture, leave it loaded;
- if it inherited a different managed fixture, restore that fixture;
- never accept an unmanaged inherited world as switchable state.

Leaving the last fixture loaded would be faster for consecutive runs but would
make ownership and crash recovery more visible to the user. This tradeoff
requires an explicit decision.

## Isolation and reuse model

### Conservative default

The normalized default is:

```lua
isolation={
    reads={'all'},
    writes={'all'},
}
```

This means:

- the current test requires a pristine realization;
- after the test, every world facet is considered dirty;
- a later mount restores before use unless its contract can establish
  compatibility through a future, more specialized rule.

Tests opt into reuse by declaring narrower facets.

### Decision rule

Let:

- `D` be the fixture's normalized dirty-facet set;
- `R` be the next test's normalized read-facet set.

The loaded realization can be reused when:

```text
D intersect R = empty
```

Otherwise, the pristine baseline must be restored and loaded before the test
continues.

After the example:

```text
D = D union W
```

where `W` is the test's normalized write-facet set.

The wildcard `all` expands to every known facet plus
`unknown_native`. Facet dependency closure must occur during normalization.
For example, advancing time may affect jobs, units, items, weather, and history
even when a test directly intended to change only the calendar.

### Initial facets

| Facet | Intended scope |
|---|---|
| `calendar_weather` | Time, season, weather, and time-driven environmental state |
| `map_tiles` | Tile materials, shapes, designations, liquids, flows, and revealed state |
| `units` | Unit existence, position, health, inventory ownership, needs, and state |
| `items` | Item existence, position, flags, containment, and ownership |
| `buildings_zones` | Buildings, stockpiles, zones, routes, and related configuration |
| `jobs_orders` | Jobs, work details, labor assignments, and manager orders |
| `fortress_state` | Economy, stocks, alerts, petitions, squads, burrows, and fortress-level configuration |
| `world_history` | Historical events, entities, figures, relationships, and off-map world changes |
| `site_persistence` | State persisted outside the immediate loaded fortress but associated with its site |
| `unknown_native` | Native state not represented by an accepted narrower facet |

This list is intentionally coarse. Overly narrow facets create incorrect reuse
through hidden dependencies. The list should only be split when a concrete
test need, restorer, and live proof justify it.

### What a reload does not restore

Restoring a world baseline does not necessarily restore:

- Lua globals or `package.loaded`;
- TestBed module graphs;
- DFHack plugin globals and persistent tables;
- event registrations;
- timers not owned by the world;
- external configuration or data files;
- keyboard, mouse, or virtual-pointer state;
- viewscreen instrumentation;
- process-global DF settings.

Those remain the responsibility of TestBed, DwarfSpec cleanup, plugin-specific
fixtures, or process isolation.

### Manual restoration

The first contract should not let a test assert that arbitrary state was
restored merely by saying so. Declared writes remain dirty.

A future extension could clear facets only through:

- a DwarfSpec-owned mutation helper with a verified inverse;
- a facet-specific verifier;
- a registered restorer that completes during cleanup;
- an explicit baseline fingerprint supported by live evidence.

A generic `world:confirmRestored()` method should not be added unless it can
provide stronger assurance than an unchecked author claim.

## Provisioning workflow

A missing fixture requires this conceptual transaction:

1. Validate the definition and reserve managed storage.
2. Resolve deterministic or random native seeds.
3. Write an operation journal.
4. Enter world generation from a supported title state.
5. Apply the normalized generation parameters.
6. Generate the world and monitor progress or rejection.
7. Select the newly generated inactive world under Start.
8. Survey candidate embark locations.
9. Select a deterministic matching location and playable civilization.
10. Apply the requested 2 by 2 or configured embark rectangle.
11. Enter the quickstart setup path.
12. Wait for both world and map load completion.
13. Establish a deterministic paused base state.
14. Request an explicit save.
15. Wait for durable save completion.
16. Return to a safe unloaded state if required for snapshot consistency.
17. Capture and validate the immutable whole-save baseline.
18. Create or refresh the working save from that baseline.
19. Complete the manifest and clear the operation journal.
20. Load or retain the working realization as the mounted fixture.

The transaction must distinguish:

- generator rejection;
- no matching embark site;
- no playable civilization;
- failed embark;
- world loaded but map not loaded;
- save requested but not durable;
- baseline copy failure;
- manifest finalization failure.

Each failure after storage reservation needs a recoverable journal state. A
partial fixture must never be treated as complete.

## Provisioning backends

### In-process native UI backend

The recommended initial backend drives the installed game's native screens
through stable DFHack viewscreen identities, declared fields, enum values, and
simulated input.

Advantages:

- no second Dwarf Fortress process;
- no race over shared preferences or save directories;
- direct access to progress, rejection, site, and viewscreen state;
- one DwarfSpec executor and diagnostic channel;
- embark can continue immediately after generation.

Risks:

- native UI details can change between Dwarf Fortress versions;
- world generation and embark require a larger state machine;
- direct structure writes may be required where no stable input path exists;
- failure recovery must survive world unload and reload.

### External `-gen` backend

Dwarf Fortress supports a command-line world-generation mode. It generates an
inactive world and exits, so the active DwarfSpec process would still need to
select the result, embark, and save it.

Advantages:

- generation can occur outside the interactive process;
- a higher-level control plane could pre-provision fixtures;
- failure may be isolated from the live test process.

Risks:

- shared-install and shared-save coordination;
- temporary world-generation preset management;
- process-launch and completion supervision;
- Dwarf Fortress or Steam single-instance behavior;
- inactive-world handoff;
- cleanup after aborted processes.

The public API should depend on a private provisioner interface so the backend
can change without altering `WorldConfig`. The in-process backend is the
recommended first implementation; the external backend remains a later
optimization or pre-provisioning tool.

Reference:

- [Dwarf Fortress command-line world generation](https://dwarffortresswiki.org/index.php/Command_line)

## Embark-site selection

### Selection precedence

`MapDefinition` should support two mutually exclusive modes:

1. `location` supplies exact region and local coordinates.
2. `site` supplies criteria for deterministic discovery.

Supplying both should be a validation error. When neither is supplied, the
system selects the first deterministic valid site that can fit the requested
rectangle and playable civilization.

### Deterministic discovery

Candidate enumeration must have a documented stable order. It should not
depend on:

- hash-table iteration;
- mouse position;
- current finder selection;
- localized text;
- screen resolution;
- nondeterministic UI timing.

The selected result and a bounded candidate summary should be recorded in the
manifest.

If no site satisfies all constraints, the command should fail with:

- normalized requested criteria;
- world realization and seeds;
- requested map dimensions;
- number of candidates examined;
- bounded rejection counts by reason;
- suggestions that do not automatically change the request.

The system must not silently relax aquifer, resource, biome, dimension, or
neighbor requirements.

### Finder implementation options

The native embark finder exposes useful but limited filters. DFHack's
`embark-assistant` demonstrates richer surveying and matching concepts.
Neither should become an undocumented mandatory dependency.

Candidate approaches are:

- drive the native finder for supported criteria;
- inspect native world and embark data through a private survey adapter;
- optionally integrate an available DFHack survey provider;
- combine a coarse native search with deterministic private verification.

The accepted implementation must work with the supported DFHack release and
must define behavior when an optional plugin is unavailable.

Reference:

- [DFHack embark-assistant](https://docs.dfhack.org/en/stable/docs/tools/embark-assistant.html)

## Save and baseline semantics

The initial fortress must be explicitly saved. The installation's
`INITIAL_SAVE` preference cannot be treated as part of the fixture contract.

A save request is not itself proof that every file is durable. The provisioner
must wait for an authoritative post-save boundary selected during live
characterization.

The pristine baseline should be captured only when:

- the expected managed world and site were loaded;
- the exact configured embark rectangle was verified;
- the expected civilization was verified;
- no world-generation or embark screen remained active;
- the initial save completed;
- the save directory was identified exactly;
- no open game process was still mutating the files being copied, or a
  demonstrated safe snapshot mechanism was used.

Autosaves and test-triggered saves can dirty the working directory even when
the in-memory world is later discarded. The dirty ledger therefore cannot be
the only restore signal. The design needs separate knowledge of:

- in-memory facet dirtiness;
- possible working-save disk dirtiness;
- baseline integrity.

When disk cleanliness is uncertain, restoration must replace the working save
from the baseline before loading.

DFHack's `quicksave` command can request an autosave, but its rolling autosave
behavior is not an immutable fixture store.

References:

- [DFHack quicksave](https://docs.dfhack.org/en/stable/docs/tools/quicksave.html)
- [DFHack load-save](https://docs.dfhack.org/en/stable/docs/tools/load-save.html)

## Transition synchronization

World transitions must use raw-frame waits. Simulation-tick waits are not
suitable because most tick-based timers are canceled or cannot make progress
while a world is unloaded or paused.

State-change callbacks are observations, not sole transaction authority.
Success should verify current state directly:

- whether a world is loaded;
- whether a map or site is loaded;
- exact current save directory;
- current viewscreen;
- managed ownership and expected realization.

The transition controller should tolerate duplicate or reordered callbacks
while rejecting an unexpected loaded world.

Useful DFHack boundaries include:

- `dfhack.isWorldLoaded()`;
- `dfhack.isMapLoaded()`;
- `dfhack.isSiteLoaded()`;
- `dfhack.world.ReadWorldFolder()`;
- `dfhack.onStateChange`;
- `dfhack.gui.simulateInput()`;
- raw-frame `dfhack.timeout()` scheduling.

Reference:

- [DFHack Lua API](https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html)

## Ownership and safety rules

- Validate logical names before filesystem work.
- Never interpret a logical name as a relative or absolute path.
- Never accept `regionN` alone as proof of ownership.
- Refuse to transition away from an unmanaged loaded world.
- Refuse a fixture whose external manifest and internal marker disagree.
- Refuse a definition mismatch rather than silently rebuilding.
- Verify exact expected world immediately before every discard action.
- Verify exact target world after every load action.
- Never save an unmanaged world as a side effect of fixture mounting.
- Never discard an unrelated world encountered during cleanup or recovery.
- Never merge a baseline into a dirty save directory.
- Journal every destructive working-save replacement.
- Quarantine the fixture and executor when safe recovery cannot be proven.
- Keep failure diagnostics bounded and avoid leaking unrelated filesystem
  contents.

Fixture deletion and explicit recreation are administrative capabilities and
should not be hidden inside `mountWorld()`.

## Diagnostics

A successful result should report:

- logical fixture name;
- action: generated, loaded, restored, or reused;
- save directory;
- requested-definition fingerprint;
- realized fingerprint;
- resolved seeds;
- selected site and civilization;
- requested and resolved map size;
- dirty facets before and after compatibility evaluation;
- elapsed provisioning, restoration, and load times when applicable.

A failure should include the relevant bounded subset of:

- operation and transition state;
- logical fixture name;
- expected and observed save directories;
- expected and observed world identity;
- requested and stored definition fingerprints;
- definition diff;
- current focus and viewscreen;
- world/map/site loaded flags;
- elapsed frames and milliseconds;
- generation progress or rejection reason;
- site-search rejection counts;
- operation-journal state;
- primary and recovery errors.

Diagnostics should say why a reload happened. Performance-sensitive tests need
to distinguish a genuine isolation conflict from a cache miss, interrupted
operation, disk-dirty restore, or definition mismatch.

## Concurrency and leases

Only one world transition may be active in a Dwarf Fortress process.

The managed-world controller should use the existing run-scoped executor and
lease concepts rather than introducing an independent unbounded coroutine.
The lease must survive raw-frame unload/load transitions and must be released
or quarantined on every terminal path.

The initial contract should reject:

- nested `mountWorld()` calls;
- a transition while an owned save-game mount is active;
- a transition after a component or native screen has mounted;
- concurrent fixture provisioning;
- external observation of an unexpected world during cleanup.

Multiple examples can request the same mounted world sequentially. That is
reuse, not concurrent ownership.

## Recovery model

The operation journal should make at least these states distinguishable:

- provisioning reserved;
- seeds resolved;
- generation started;
- world generated but inactive;
- embark selected;
- fortress entered;
- initial save requested;
- initial save verified;
- baseline capture started;
- baseline verified;
- working restore started;
- working save verified;
- manifest completion started;
- complete.

On startup or first fixture access:

- a complete manifest and absent journal allow normal evaluation;
- an interrupted non-destructive operation may resume;
- an interrupted destructive replacement must verify both source and target
  before continuing;
- an ambiguous baseline must quarantine the fixture;
- an unowned target must never be removed during recovery.

Recovery policy should prefer leaving an incomplete fixture unavailable over
guessing that a partial save is valid.

## Testing strategy

### Focused standalone coverage

Use injected adapters to test:

- configuration validation and normalization;
- default seed and `"random"` semantics;
- stable four-seed derivation;
- canonical fingerprints and definition diffs;
- logical-name and path safety;
- ownership verification;
- isolation wildcard expansion and dependency closure;
- dirty-set intersection decisions;
- example cleanup ledger updates;
- same-world reuse;
- conflicting-world restore;
- different-managed-world transitions;
- unmanaged-world refusal;
- manifest and journal state transitions;
- interruption recovery;
- composed primary and recovery failures;
- bounded diagnostics.

### Transition characterization

Selected live probes should establish:

- stable discard-without-saving input;
- raw-frame callback survival across unload;
- exact state-change ordering as observation;
- stable title and load-screen identities;
- exact active-save selection;
- authoritative save-completion detection;
- safe whole-directory baseline capture;
- deterministic embark rectangle and site application.

Characterization probes must remain separately selected from ordinary live
test globs.

### Selected live fixture coverage

Use explicitly disposable managed fixtures to prove:

- default deterministic generation from a missing fixture;
- realized seed recording;
- default 2 by 2 embark;
- durable initial save and baseline creation;
- a second compatible example reuses without world events;
- a conflicting example restores the baseline;
- disjoint dirty and read facets permit reuse;
- an undeclared example leaves all facets dirty;
- an unavailable site fails without relaxing constraints;
- an assertion failure still records dirtiness;
- an unexpected unmanaged world is not discarded;
- interrupted-operation recovery is bounded;
- final DwarfSpec cleanup state is confirmed.

### Evidence boundaries

Keep these results distinct:

- focused standalone unit tests;
- full standalone unit suite;
- Lua syntax and formatting;
- package construction and archive audit;
- selected live transition probes;
- selected live world provisioning;
- complete live suite;
- final process and cleanup state.

Mocked state-machine coverage is not proof that Dwarf Fortress generated,
embarked, saved, restored, or loaded a world.

## Proposed workstreams

1. Public types, normalization, and definition identity.
2. Isolation facets, dependency closure, and dirty-ledger semantics.
3. Project-scoped manifest, ownership marker, and storage layout.
4. Shared private world transition controller and diagnostics.
5. In-process world-generation driver.
6. Embark survey, matching, and deterministic site selection.
7. Quickstart embark, initial save, and durable-save verification.
8. Baseline capture, working-save replacement, and recovery journal.
9. Run-scoped world fixture lifecycle and example cleanup integration.
10. Focused tests, selected live probes, documentation, and packaging.

Each workstream should receive its own refined contract before implementation.
The generation and baseline workstreams are expensive live boundaries and
should not be inferred complete from isolated unit tests.

## Open questions

### Public contract

- Should the `WorldMount` result remain a read-only data record, or should it
  expose carefully bounded query methods?
- Should unknown configuration fields fail immediately to catch misspellings?
- What numeric range and textual normalization should the master seed accept?
- Should fixture recreation be a separate DwarfSpec command, a command-line
  tool, or intentionally manual at first?

### Definition

- Which world-generation settings must be configurable in the first useful
  version beyond size, history, seed, and playable-civilization requirement?
- What embark width and height bounds can be supported independently of the
  player's configured maximum embark size?
- Which embark-site criteria have sufficiently stable native data and clear
  semantics?
- Should exact embark coordinates include world identity checks to prevent
  accidental reuse against a different realization?
- Does starting-party configuration belong in `EmbarkDefinition` immediately,
  or should quickstart be the only initial mode?
- How many deterministic generation attempts are allowed when world generation
  rejects valid settings?

### Isolation

- Is the initial facet list appropriately coarse?
- Which facet dependencies should automatically expand declared reads and
  writes?
- Should the dirty ledger persist across DwarfSpec runs?
- Can any initial DwarfSpec mutation helpers provide verified automatic
  restoration?
- Should a test be allowed to declare no writes explicitly, and how visible
  should that risk be in diagnostics?

### Lifecycle

- What should final run cleanup restore when the run began at title?
- May a run begin with an already loaded managed fixture and borrow it?
- Should every `mountWorld()` call be the first stateful command, even when the
  fixture can be reused without a transition?
- When should a loaded but disk-dirty working save be replaced from baseline?
- Should a compatible world remain loaded between separate test-runner
  invocations?

### Storage and compatibility

- Where should project-scoped immutable baselines live?
- How should project identity be derived and moved safely?
- What raw/mod fingerprint is both stable and affordable?
- Which Dwarf Fortress or DFHack upgrades invalidate a fixture?
- Which file-copy or rename strategy is safe while the game process is
  running?
- How should storage quotas and stale fixture cleanup be administered?

### Provisioning

- Which native viewscreen fields and inputs form the supported in-process
  generation path?
- Is a direct parameter adapter preferable to driving every advanced-generation
  field through UI input?
- What is the authoritative durable-save boundary?
- Can site discovery be implemented without a required optional plugin?
- When, if ever, should the external `-gen` backend be implemented?

## Next discussion

The next useful design discussion should settle the normalized
`WorldDefinition` surface:

1. exact first-version `WorldGenerationDefinition` fields;
2. exact first-version `MapDefinition` site criteria;
3. exact master-seed input range and four-seed derivation contract;
4. whether quickstart is the only initial embark mode.

Those choices determine fixture identity and manifest compatibility. The
transition, storage, and isolation implementations should not begin until that
definition can be normalized and fingerprinted without ambiguity.
