# Managed world mounting proposal

## Status

This document is an exploratory design proposal for a future managed-world
fixture system. It records the current agreements, identifies unresolved
contracts, and separates the feature into independently refinable workstreams.
It is not an implementation checklist and does not describe shipped DwarfSpec
behavior.

The proposed entry point is:

```lua
ds.mountWorld(definition, isolation)
```

The system would provision, load, reuse, and restore DwarfSpec-owned worlds for
live tests. Provisioning includes world generation, deterministic embark-site
selection, entering fortress mode, making an initial save, and capturing a
recovery snapshot.

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

- The public entry point is `ds.mountWorld(definition, isolation)`.
- `WorldDefinition.name` is the fixture identity and requested Dwarf Fortress
  save-game name. It must be one safe directory name, never a path.
- World definitions are reusable project-level values. Each test passes its
  own optional `WorldIsolation` argument independently.
- Managed fixture manifests and recovery snapshots live beneath
  `<project-root>/.dwarfspec/worlds`.
- `<project-root>/.dwarfspec/worlds/project.json` retains a random persistent
  project UUID. Each fixture manifest retains its own random fixture UUID.
- Every managed save directory contains `.dwarfspec-world.json`; its project
  UUID, fixture UUID, and fixture name must match the project-local manifest.
- `mountWorld()` refuses unmanaged, orphaned, mismatched, foreign, or
  ambiguously located save-name collisions. Adoption, deletion, and relocation
  are separate administrative operations.
- `WorldDefinition` contains a `MapDefinition` describing the desired embark
  map.
- The default generated world is deliberately small.
- The default embark rectangle is 2 by 2 local embark tiles.
- The world-generation master seed defaults to `0` for repeatability.
- The string `"random"` requests random generation during initial
  provisioning.
- A deterministic master seed is written to all four native Dwarf Fortress
  seed fields.
- A random fixture records its resolved native seeds and reuses the realized
  world on later mounts.
- The first public `WorldGenerationDefinition` contains only `seed`,
  `world_size`, and `history_years`.
- Playable-civilization enforcement and the remaining advanced world-generation
  settings belong to a versioned internal fast-generation profile.
- `MapDefinition` accepts either strict site criteria or one exact location,
  but never both.
- The initial strict site criteria are aquifer, flux, clay, sand, river, and
  required metals.
- DwarfSpec exposes immutable constants for the eleven canonical vanilla ore
  metals while accepting custom raw metal identifiers.
- The first implementation always uses quickstart. Custom embark profiles are
  deferred to a later follow-up.
- A test that does not declare its isolation behavior conservatively requires
  a pristine world and leaves the entire world dirty.
- Isolation uses `requires` for facets that must be pristine and `dirties` for
  facets that a test may mutate.
- DwarfSpec exposes the accepted facets through an immutable
  `ds.EWorldFacet` enum.
- Advancing fortress simulation dirties every facet in the first
  implementation.
- The dirty ledger is run-scoped in memory and is never persisted across a
  Dwarf Fortress process restart.
- The first managed-world mount in a new DwarfSpec run verifies the managed
  save's recorded `world.sav` sentinel before loading it. It restores the
  recovery snapshot only when that file indicates the save has changed.
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
- Reload the initially saved state when a test requires facets that an earlier
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

- **Fixture name:** `WorldDefinition.name`, such as `"stockpile-fixture"`.
  It identifies the fixture and is used as its Dwarf Fortress save-game
  directory name after validation.
- **Definition:** The immutable requested properties used to identify a
  fixture. Generation, embark-map, and initial-embark settings belong to the
  definition.
- **Realization:** The concrete generated world associated with a definition.
  It includes the four native Dwarf Fortress seeds, world identity,
  civilization, site, local embark rectangle, and save directory.
- **Managed save image:** The DwarfSpec-owned save directory that Dwarf
  Fortress loads. Ordinary play mutates the world in memory without changing
  this image unless a save occurs.
- **Recovery snapshot:** An immutable whole-save copy made immediately after
  successful initial embark and durable save. It is used only to repair a
  managed save image that was changed on disk.
- **Facet:** A coarse category of world state used to decide whether a working
  world is compatible with a later test.
- **Dirty ledger:** The run-scoped in-memory set of facets that may differ from
  the fixture's initially saved state.
- **Managed world:** A world whose manifest, ownership marker, definition,
  realization, managed save image, and recovery snapshot have all been
  verified by DwarfSpec.
- **Unmanaged world:** Any loaded or stored world that DwarfSpec cannot prove
  it owns.

## Proposed public API

### Basic deterministic fixture

```lua
local default_world = {
    name='default-fixture',
}

local world = ds.mountWorld(default_world)

assert.equals('default-fixture', world.name)
assert.equals(2, world.map.size.width)
assert.equals(2, world.map.size.height)
```

Omitting `isolation` uses the conservative isolation policy. All definition
fields other than `name` receive their documented defaults.

### Defined fixture

```lua
---@type dwarfspec.WorldDefinition
local stockpile_world = {
    name='stockpile-fixture',
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
            metals={
                ds.ECanonicalMetal.IRON,
            },
        },
    },
}

local isolation = {
    requires={
        ds.EWorldFacet.MAP_TILES,
        ds.EWorldFacet.UNITS,
        ds.EWorldFacet.ITEMS,
    },
    dirties={
        ds.EWorldFacet.JOBS_ORDERS,
        ds.EWorldFacet.ITEMS,
    },
}

local world = ds.mountWorld(stockpile_world, isolation)
```

### Random initial generation

```lua
local exploratory_world = {
    name='exploratory-fixture',
    generation={
        seed='random',
    },
}

local world = ds.mountWorld(exploratory_world)
```

`"random"` means random when the fixture is first provisioned. It does not
mean random on every mount. The manifest stores the resolved seeds, and later
mounts reuse the same realization until the fixture is explicitly recreated.

### Authoring-time types

The first-version world and map definition fields below are accepted. The
authoritative production annotations and `ds.d.lua` declarations must
eventually use these canonical types rather than parallel copies.

```lua
---Selects the requested master-seed behavior for world generation.
---Integers are restricted to the inclusive range from 0 to `math.maxinteger`.
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

---Identifies a canonical vanilla metal that can occur in an ore.
---@alias dwarfspec.CanonicalMetal
---| '"ALUMINUM"'
---| '"BISMUTH"'
---| '"COPPER"'
---| '"GOLD"'
---| '"IRON"'
---| '"LEAD"'
---| '"NICKEL"'
---| '"PLATINUM"'
---| '"SILVER"'
---| '"TIN"'
---| '"ZINC"'

---Provides immutable constants for canonical vanilla ore-metal identifiers.
---@class dwarfspec.ECanonicalMetalEnum
---@field ALUMINUM `ALUMINUM`
---@field BISMUTH `BISMUTH`
---@field COPPER `COPPER`
---@field GOLD `GOLD`
---@field IRON `IRON`
---@field LEAD `LEAD`
---@field NICKEL `NICKEL`
---@field PLATINUM `PLATINUM`
---@field SILVER `SILVER`
---@field TIN `TIN`
---@field ZINC `ZINC`

---Identifies one coarse category of mutable world state.
---@alias dwarfspec.WorldFacet
---| '"all"'
---| '"calendar_weather"'
---| '"simulation_state"'
---| '"map_tiles"'
---| '"units"'
---| '"items"'
---| '"buildings_zones"'
---| '"jobs_orders"'
---| '"fortress_state"'
---| '"world_history"'
---| '"site_persistence"'
---| '"unknown_native"'

---Provides immutable constants for accepted world-isolation facets.
---@class dwarfspec.EWorldFacetEnum
---@field ALL `all`
---@field CALENDAR_WEATHER `calendar_weather`
---@field SIMULATION_STATE `simulation_state`
---@field MAP_TILES `map_tiles`
---@field UNITS `units`
---@field ITEMS `items`
---@field BUILDINGS_ZONES `buildings_zones`
---@field JOBS_ORDERS `jobs_orders`
---@field FORTRESS_STATE `fortress_state`
---@field WORLD_HISTORY `world_history`
---@field SITE_PERSISTENCE `site_persistence`
---@field UNKNOWN_NATIVE `unknown_native`

---Reports how a requested fixture reached its mounted state.
---@alias dwarfspec.WorldMountAction
---| '"generated"'
---| '"loaded"'
---| '"restored"'
---| '"reused"'

---Defines the size of a local embark rectangle.
---@class dwarfspec.MapSize
---@field width? integer Defaults to 2; accepts 2 through 16.
---@field height? integer Defaults to 2; accepts 2 through 16.

---Defines strict criteria used to select a valid embark site.
---@class dwarfspec.EmbarkSiteCriteria
---@field aquifer? dwarfspec.AquiferRequirement Defaults to `"any"`.
---@field flux? boolean True requires presence; false requires absence.
---@field clay? boolean True requires presence; false requires absence.
---@field sand? boolean True requires presence; false requires absence.
---@field river? boolean True requires presence; false requires absence.
---@field metals? string[] Canonical constants or exact custom raw identifiers.

---Selects the upper-left local tile of an exact embark location.
---@class dwarfspec.ExactEmbarkLocation
---@field region_x integer
---@field region_y integer
---@field local_x integer
---@field local_y integer

---Defines the playable map created by embarking.
---@class dwarfspec.MapDefinition
---@field size? dwarfspec.MapSize Defaults to a 2 by 2 embark rectangle.
---@field site? dwarfspec.EmbarkSiteCriteria
---@field location? dwarfspec.ExactEmbarkLocation Mutually exclusive with `site`.

---Defines the generated world that will contain the embark site.
---@class dwarfspec.WorldGenerationDefinition
---@field seed? dwarfspec.WorldSeed Defaults to `0`.
---@field world_size? dwarfspec.WorldSize Defaults to `"pocket"`.
---@field history_years? integer Defaults to 2.

---Defines the immutable properties of one managed world fixture.
---@class dwarfspec.WorldDefinition
---@field name string Fixture identity and safe Dwarf Fortress save-game name.
---@field generation? dwarfspec.WorldGenerationDefinition
---@field map? dwarfspec.MapDefinition

---Declares the pristine state required and possible mutations for one test.
---@class dwarfspec.WorldIsolation
---@field requires? dwarfspec.WorldFacet[] Defaults to `{"all"}`.
---@field dirties? dwarfspec.WorldFacet[] Defaults to `{"all"}`.

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

---Provides canonical vanilla ore-metal identifiers.
---@type dwarfspec.ECanonicalMetalEnum
DS.ECanonicalMetal = nil

---Provides accepted world-isolation facets.
---@type dwarfspec.EWorldFacetEnum
DS.EWorldFacet = nil

---Mounts a managed world fixture for the current example.
---@param definition dwarfspec.WorldDefinition
---@param isolation? dwarfspec.WorldIsolation
---@return dwarfspec.WorldMount
function DS.mountWorld(definition, isolation) end
```

The criteria fields above are an initial vocabulary, not an accepted complete
surface. Each accepted criterion will need a precise type, normalization rule,
default, matching definition, diagnostic rendering, and live feasibility
proof.

## Default definition

The accepted normalized default definition is:

```lua
{
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
        site={},
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
- The internal fast-generation profile requires a playable civilization and
  supplies all advanced settings that are not part of the public definition.

The default definition does not require flux, clay, sand, a river, a metal, or
the absence of aquifers. Such constraints can make a tiny world substantially
harder or impossible to provision and should be explicit.

References:

- [Dwarf Fortress world generation](https://dwarffortresswiki.org/index.php/World_generation)
- [Dwarf Fortress advanced world generation](https://dwarffortresswiki.org/index.php/Advanced_world_generation)
- [Dwarf Fortress embark](https://dwarffortresswiki.org/index.php/Embark)

## Master-seed semantics

Dwarf Fortress uses distinct world, history, name, and creature seeds. The
public proposal intentionally exposes one master seed for the common case.

For an integer master seed:

1. Normalize the integer to one canonical textual representation.
2. Write that exact representation to all four native seed fields.
3. Record the master seed and four native values in the manifest.

For example, `seed=0` resolves to:

```text
world seed    = "0"
history seed  = "0"
name seed     = "0"
creature seed = "0"
```

Accepted deterministic master seeds are integers from `0` through
`math.maxinteger`. Canonical encoding is base-10 ASCII without a sign, leading
zeroes, separators, whitespace, locale-sensitive formatting, or scientific
notation.

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

1. Validate `WorldDefinition.name`, the definition, and the isolation argument.
2. Apply all documented defaults.
3. Canonicalize maps, arrays, enums, integers, and absent optional fields.
4. Reject unknown fields unless the compatibility policy later permits them.
5. Compute a requested-definition fingerprint.

The fingerprint should include at least:

- managed-world schema version;
- seed mode and deterministic master seed when applicable;
- normalized generation settings;
- normalized map size and site criteria;
- internal fast-generation profile version;
- fixed quickstart provisioning contract version;
- Dwarf Fortress save compatibility version;
- DFHack compatibility version where transition behavior requires it;
- ordered raw and mod identity;
- provisioning-backend contract version.

The separate per-test isolation argument must not participate in fixture
identity. Tests can reuse the same `WorldDefinition` value while independently
declaring different required and dirtied facets.

When a fixture name already exists:

- an identical requested definition may reuse its realization;
- a different requested definition must fail with a bounded definition diff;
- DwarfSpec must not silently regenerate or replace the existing fixture;
- explicit recreation should be a separate administrative operation, not an
  option on ordinary `mountWorld()`.

## Manifest and storage model

Managed fixture storage is project-local beneath:

```text
<project-root>/.dwarfspec/worlds/
```

This directory contains generated test artifacts and should normally be
excluded from source control. It remains separate from arbitrary player saves,
while the project root provides the authoritative scope already used by the
DwarfSpec runner.

One fixture conceptually contains:

```text
<project-root>/.dwarfspec/worlds/
  project.json
  <fixture-name>/
    manifest.json
    operation-journal.json
    recovery/
      <whole save directory>
```

Dwarf Fortress loads the managed save image beneath its active save root.
`WorldDefinition.name` supplies that save-game directory name directly. The
manifest maps it to the resolved save root without accepting a path from test
code.

`project.json` uses schema `dwarfspec.world-project.v1` and stores a random
persistent project UUID. This identity is distinct from the process-local
scheduler project ID. Moving the project with its `.dwarfspec` directory
preserves fixture ownership; a fresh clone without generated storage receives
a new identity.

Each fixture receives a random persistent fixture UUID. Its managed save
directory contains:

```text
<resolved-save-root>/<fixture-name>/
  .dwarfspec-world.json
  world.sav
  ...
```

The marker uses schema `dwarfspec.managed-world.v1` and contains only:

```json
{
  "schema": "dwarfspec.managed-world.v1",
  "project_id": "<project UUID>",
  "fixture_id": "<fixture UUID>",
  "name": "<fixture name>"
}
```

The marker deliberately excludes the dirty ledger, `world.sav` sentinel, and
other mutable operational state. It must remain readable while the world is
unloaded, before DwarfSpec performs any filesystem repair.

The manifest should record:

- fixture and save-game name;
- persistent project and fixture UUIDs;
- requested definition and fingerprint;
- realized definition and fingerprint;
- four resolved native seeds;
- generated world identity;
- selected civilization;
- region and local embark coordinates;
- embark rectangle;
- managed save-image directory and recorded `world.sav` last-write time and
  size;
- recovery-snapshot identity and integrity information;
- Dwarf Fortress and DFHack compatibility information;
- last completed operation;
- interrupted filesystem-operation state.

The manifest does not persist per-test facet dirtiness. Every new DwarfSpec run
starts without trusted in-memory reuse history. Before its first load of an
existing fixture, it compares `world.sav` with the sentinel recorded
immediately after provisioning or repair.

The managed save is owned only when:

- `project.json`, the fixture manifest, and `.dwarfspec-world.json` are valid;
- their project UUIDs match;
- the manifest and marker fixture UUIDs and names match exactly;
- the directory name exactly matches `WorldDefinition.name`;
- the requested definition fingerprint matches the manifest;
- the resolved save directory is an immediate child of the recorded save
  root; and
- exactly one DF-visible save root contains the requested directory name.

The marker prevents accidental destruction; it is not a security boundary. A
matching directory name alone is never proof of ownership.

Name collisions follow this contract:

| Project manifest | Save directory | Marker | Result |
|---|---|---|---|
| Missing | Missing | Not applicable | Provision a new fixture |
| Present | Present | Matches | Verify and mount |
| Present | Missing | Not applicable | Recreate from the recovery snapshot |
| Missing | Present | Missing | Refuse an unmanaged player save |
| Missing | Present | Present | Refuse an orphaned or foreign fixture |
| Present | Present | Missing | Refuse because ownership evidence is incomplete |
| Present | Present | Mismatched | Refuse an ownership conflict |
| Present | Present | Matches, but definition differs | Refuse with a definition diff |

Ordinary `mountWorld()` never adopts, renames, deletes, relocates, or
overwrites a conflicting save.

Fixture names may contain ordinary characters and spaces, as in
`"TestWorld 01"`, but must be one portable directory component. Validation
rejects:

- empty names, `.` and `..`;
- `/`, `\`, absolute paths, and control characters;
- trailing spaces or periods;
- platform-reserved device names;
- `current`, which Dwarf Fortress reserves; and
- case-insensitive collisions on a case-insensitive filesystem.

DwarfSpec never silently sanitizes a fixture name.

The manifest records the canonical absolute save root selected during
provisioning. Before mounting, DwarfSpec locates every DF-visible save
directory with the requested name:

- exactly one at the recorded root permits evaluation;
- none, with a valid manifest and recovery snapshot, permits recreation;
- more than one is an ambiguous collision and is refused; and
- one at an unexpected root is refused until an explicit relocation operation
  is defined.

Ordinary isolation reloads the unchanged managed save image without copying
files. If the `world.sav` sentinel changed, exceptional repair restores the
whole directory by replacement, never by merging recovery files over it.
Residual files from a later save can otherwise survive and corrupt the
restored state.

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
- example cleanup records the fixture's declared dirtiness in the run-scoped
  ledger;
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

- require `WorldDefinition.name` to be one nonempty safe save-directory name;
- normalize and fingerprint the definition;
- normalize isolation independently;
- acquire the one process-wide world-transition lease;
- inspect current world, map, viewscreen, and managed ownership;
- reject incompatible example-owned stateful resources;
- reject an unmanaged loaded world;
- inspect the fixture manifest, journal, recovery snapshot, managed save-image
  `world.sav` sentinel, and status;
- choose one explicit mount action.

The initial contract should require `mountWorld()` to be the first stateful
DwarfSpec operation in an example. This protects LIFO cleanup and prevents
subjects, screens, pointers, or other world-bound handles from surviving a
world transition.

### Mount action

| Current state | Requested state | Action |
|---|---|---|
| Same managed realization loaded and compatible | Existing fixture | Reuse |
| Same managed realization loaded but incompatible | Existing fixture | Discard without saving and reload the same managed save image; repair first only if its `world.sav` sentinel changed |
| Different managed realization loaded | Existing fixture | Discard current managed world and load target |
| No world loaded | Existing pristine fixture | Load target |
| No completed fixture exists | Valid missing fixture | Provision, save, capture recovery snapshot, and mount |
| Incomplete operation exists | Recoverable fixture | Recover, then reevaluate |
| Unmanaged world loaded | Any fixture | Refuse without changing it |
| Definition fingerprint differs | Existing fixture name | Refuse with a definition diff |

### Example cleanup

Cleanup should occur after all stateful resources created after the world mount
have been released.

World cleanup should:

- verify that the expected managed realization is still loaded;
- fail safely if an unrelated world appeared;
- union normalized declared and observed dirtiness into the run-scoped ledger;
- release the example's fixture claim;
- leave the compatible managed world loaded for possible reuse;
- preserve `cleanup_confirmed=false` when ownership or the in-memory ledger
  update cannot be proven.

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

Regardless of final run-state policy, a later DwarfSpec run does not inherit
the prior run's dirty ledger. Its first mount verifies the requested fixture's
`world.sav` sentinel and loads the managed save image directly when it is
unchanged. A Dwarf Fortress process crash needs no special facet recovery
because both DwarfSpec and the in-memory world disappear together.

## Isolation and reuse model

### Conservative default

The normalized default is:

```lua
isolation={
    requires={ds.EWorldFacet.ALL},
    dirties={ds.EWorldFacet.ALL},
}
```

This means:

- the current test requires a pristine realization;
- after the test, every world facet is considered dirty;
- a later mount in the same DwarfSpec run restores unless its contract can
  establish compatibility.

Tests opt into reuse by declaring narrower facets.

### Normalization

`requires` describes facets that must match the initially saved state before the
test. `dirties` describes facets that the test may mutate and that DwarfSpec
must conservatively mark dirty after cleanup.

Normalization follows these rules:

- omitting `isolation` defaults both fields to `ALL`;
- omitting either field defaults that field independently to `ALL`;
- an explicit empty `requires` accepts any in-run dirty world state;
- an explicit empty `dirties` promises that the test does not mutate
  world-owned state;
- `ALL` must be the only member when present;
- duplicate or unknown facets are errors;
- input arrays are copied and normalized into stable enum order.

Empty `dirties` is reserved for genuinely read-only tests. A test that mutates
and manually restores a facet must still declare that facet dirty in the first
implementation.

### Decision rule

Let:

- `D` be the fixture's run-scoped dirty-facet set;
- `R` be the next test's normalized required-facet set.

The loaded realization can be reused when:

```text
D intersect R = empty
```

`unknown_native` in `D` blocks every reuse because its effect cannot be bounded
to an accepted narrower facet.

Otherwise, DwarfSpec must discard without saving and reload the unchanged
managed save image before the test continues. A recovery copy is required only
if the image's `world.sav` sentinel changed.

After the example:

```text
D = D union declared_dirties union observed_dirties
```

`ALL` expands to every known facet plus `unknown_native`.

The initial implementation does not apply a broad static dependency graph
between ordinary facets. Test authors declare every facet they may affect, and
DwarfSpec-owned mutation commands add every facet their production contracts
identify.

Observed fortress simulation advancement adds `ALL`. Raw-frame waits while the
fortress remains paused add nothing. An operation whose world effects cannot
be classified adds `unknown_native`.

### Initial facets

| Facet | Intended scope |
|---|---|
| `calendar_weather` | Time, season, weather, and time-driven environmental state |
| `simulation_state` | RNG state, simulation counters, pending internal events, and other future-outcome state |
| `map_tiles` | Tile materials, shapes, designations, liquids, flows, temperatures, plants, revealed state, and map features |
| `units` | Unit existence, position, health, skills, attributes, needs, relationships, and unit-side inventory references |
| `items` | Item existence, position, wear, flags, containment, ownership, and item-side holder references |
| `buildings_zones` | Buildings, constructions, stockpiles, zones, routes, and related configuration |
| `jobs_orders` | Jobs, tasks, manager orders, work details, labor assignments, and job queues |
| `fortress_state` | Alerts, squads, burrows, nobles, petitions, mandates, economy, population, wealth, and fortress-wide configuration |
| `world_history` | Historical events, entities, figures, relationships, and off-map world changes |
| `site_persistence` | Site records and state associated with the fortress but stored outside the immediate loaded map |
| `unknown_native` | Native state not represented by an accepted narrower facet |

This list is intentionally coarse. Overly narrow facets create incorrect reuse
through hidden dependencies. The list should only be split when a concrete
test need, restorer, and live proof justify it.

### Run and process boundaries

The dirty ledger exists only for one DwarfSpec run in the live Dwarf Fortress
process. It is not stored in the fixture manifest.

On the first mount of an existing fixture in a new run, DwarfSpec verifies its
managed save-image `world.sav` sentinel and loads it directly when unchanged.
Subsequent examples in that run may reuse the in-memory realization through
the facet decision rule.

If Dwarf Fortress exits or crashes, the ledger and in-memory mutations vanish
with the process. The next process verifies and loads the same managed save
image. If its `world.sav` sentinel changed, recovery-snapshot replacement
occurs before loading it.

### What a reload does not restore

Reloading a managed save image does not necessarily restore:

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
restored merely by saying so. Declared dirtiness remains dirty.

A future extension could clear facets only through:

- a DwarfSpec-owned mutation helper with a verified inverse;
- a facet-specific verifier;
- a registered restorer that completes during cleanup;
- an explicit saved-state fingerprint supported by live evidence.

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
17. Record the managed save image's `world.sav` last-write time and size.
18. Capture and validate the immutable whole-save recovery snapshot.
19. Complete the manifest and clear the operation journal.
20. Load or retain the managed realization as the mounted fixture.

The transaction must distinguish:

- generator rejection;
- no matching embark site;
- no playable civilization;
- failed embark;
- world loaded but map not loaded;
- save requested but not durable;
- recovery-snapshot copy failure;
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
can change without altering `WorldDefinition`. The in-process backend is the
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

Each embark dimension accepts 2 through 16 and defaults to 2. A request that
exceeds the installed maximum-embark setting fails with a capability error;
DwarfSpec does not change that persistent player preference. An exact
location's local coordinates identify the upper-left tile, and the complete
rectangle must fit within the region tile's 16 by 16 local grid.

### Accepted first-version criteria

The first implementation supports:

- `aquifer`;
- `flux`;
- `clay`;
- `sand`;
- `river`; and
- `metals`.

For `flux`, `clay`, `sand`, and `river`:

- `true` requires the property somewhere in the selected rectangle;
- `false` requires the property to be absent everywhere in the rectangle; and
- an omitted field does not constrain the property.

Aquifer values have these strict meanings:

| Value | Required rectangle state |
|---|---|
| `"any"` | No aquifer constraint |
| `"none"` | No light or heavy aquifer anywhere |
| `"light"` | Light aquifer present and heavy aquifer absent |
| `"heavy"` | Heavy aquifer present |
| `"light_or_none"` | Heavy aquifer absent |

`metals` is an order-independent list of raw metal identifiers. Every listed
metal must be obtainable from an ore present somewhere in the selected
rectangle. Duplicate identifiers are rejected during definition normalization.

DwarfSpec exposes the canonical vanilla ore-metal identifiers through one
immutable string enum:

```lua
local site = {
    metals={
        ds.ECanonicalMetal.IRON,
        ds.ECanonicalMetal.COPPER,
        'MY_MODDED_METAL',
    },
}
```

The canonical members are:

```text
ALUMINUM
BISMUTH
COPPER
GOLD
IRON
LEAD
NICKEL
PLATINUM
SILVER
TIN
ZINC
```

These are the vanilla metals referenced as products by `METAL_ORE` raw tokens.
Manufactured alloys such as bronze and steel are not geological site
properties and are not included.

A custom string is accepted when it exactly identifies a loaded inorganic raw
that is obtainable from at least one ore. Custom identifiers remain
case-sensitive and are included in raw/mod compatibility fingerprints.
An unknown, nonmetal, or non-ore-obtainable identifier is a definition error.

The native finder is only a candidate-discovery accelerator. Its results are
best-fit rather than strict, so DwarfSpec must independently verify every
accepted property across the final rectangle.

Soil, savagery, evilness, climate, elevation, biome count, and neighbor
criteria are deferred until their rectangle-wide semantics and verification
contracts are separately accepted.

### Initial embark behavior

The first implementation always uses the native quickstart path after selecting
the site and civilization. `WorldDefinition` does not expose an embark profile
field yet.

Custom starting dwarves, skills, equipment, animals, points, and profiles are a
later follow-up. Adding that capability will extend `WorldDefinition` and its
fingerprint schema without changing the accepted first-version map contract.

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

## Save-image and recovery semantics

The initial fortress must be explicitly saved. The installation's
`INITIAL_SAVE` preference cannot be treated as part of the fixture contract.

A save request is not itself proof that every file is durable. The provisioner
must wait for an authoritative post-save boundary selected during live
characterization.

The managed save-image `world.sav` sentinel and recovery snapshot should be
captured only when:

- the expected managed world and site were loaded;
- the exact configured embark rectangle was verified;
- the expected civilization was verified;
- no world-generation or embark screen remained active;
- the initial save completed;
- the save directory was identified exactly;
- no open game process was still mutating the files being copied, or a
  demonstrated safe snapshot mechanism was used.

There is no need to intercept save events. Before loading a managed save image
for the first time in a run, and before reloading it after an incompatible
test, DwarfSpec compares the current `world.sav` last-write time and size with
the sentinel recorded after provisioning or the last repair. When a world is
currently loaded, this check occurs only after DwarfSpec has discarded it
without saving and reached a filesystem-safe unloaded state.

`world.sav` is the save-event sentinel. DwarfSpec does not scan the companion
files for change detection. If `world.sav` is present and both recorded
attributes are unchanged, DwarfSpec treats the managed save image as unchanged
and loads it directly. A missing file or changed attribute conservatively
treats the image as changed on disk and causes recovery before loading.

This narrow sentinel depends on a native invariant: every fortress save that
can alter the managed save image rewrites `world.sav`. A controlled live
characterization must prove that invariant for manual save, autosave, and
DFHack-triggered save paths before implementation relies on it.

The local `TestWorld 01` save supports this design. It contains 16 files and
2,244,752 bytes. `world.sav` contains 2,178,034 bytes, or 97.03 percent of the
directory, and is the only vanilla file whose last-write time matches the
completed save. The `unit-*.dat`, `feature-*.dat`, `art_image-*.dat`, and
`region_snapshot-*.dat` files retain earlier timestamps. The three
`dfhack-*.dat` files changed shortly before `world.sav` and are unsuitable as
vanilla save sentinels because DFHack can manage them independently.

The companion vanilla files are still part of a valid save. A detected change
therefore causes whole-directory replacement from the recovery snapshot rather
than replacement of `world.sav` alone.

Autosaves and test-triggered saves can change the managed save image even when
the in-memory world is later discarded. The dirty ledger therefore cannot be
the only restore signal. The design keeps separate knowledge of:

- in-memory facet dirtiness;
- managed save-image `world.sav` sentinel;
- recovery-snapshot integrity.

Ordinary facet restoration discards without saving and reloads the unchanged
managed save image. Only a changed `world.sav` sentinel causes whole-directory
replacement from the recovery snapshot.

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

- Validate fixture names before filesystem work.
- Never interpret a fixture name as a relative or absolute path.
- Never accept `regionN` alone as proof of ownership.
- Require matching persistent project and fixture UUIDs in the project-local
  manifest and managed-save marker.
- Require exactly one matching fixture name across all DF-visible save roots.
- Refuse every unmanaged, orphaned, foreign, mismatched, or ambiguous
  collision.
- Refuse to transition away from an unmanaged loaded world.
- Refuse a fixture whose external manifest and internal marker disagree.
- Refuse a definition mismatch rather than silently rebuilding.
- Verify exact expected world immediately before every discard action.
- Verify exact target world after every load action.
- Never save an unmanaged world as a side effect of fixture mounting.
- Never discard an unrelated world encountered during cleanup or recovery.
- Never merge a recovery snapshot into a changed managed save directory.
- Journal every destructive managed-save replacement.
- Quarantine the fixture and executor when safe recovery cannot be proven.
- Keep failure diagnostics bounded and avoid leaking unrelated filesystem
  contents.

Fixture deletion and explicit recreation are administrative capabilities and
should not be hidden inside `mountWorld()`.

## Diagnostics

A successful result should report:

- fixture name;
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
- fixture name;
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
- `world.sav` sentinel recorded;
- recovery-snapshot capture started;
- recovery snapshot verified;
- managed-save repair started, when required;
- managed save verified;
- manifest completion started;
- complete.

On startup or first fixture access:

- a complete manifest and absent journal allow normal evaluation;
- an interrupted non-destructive operation may resume;
- an interrupted destructive replacement must verify both source and target
  before continuing;
- an ambiguous recovery snapshot must quarantine the fixture;
- an unowned target must never be removed during recovery.

Recovery policy should prefer leaving an incomplete fixture unavailable over
guessing that a partial save is valid.

## Testing strategy

### Focused standalone coverage

Use injected adapters to test:

- configuration validation and normalization;
- default seed and `"random"` semantics;
- deterministic master-seed replication to all four native seed fields;
- independent random-seed resolution and persistence;
- canonical and custom ore-metal validation;
- canonical fingerprints and definition diffs;
- logical-name and path safety;
- ownership verification;
- isolation omission, empty-list, wildcard, duplicate, and enum normalization;
- simulation and unknown-native observed-dirtiness escalation;
- dirty-set intersection decisions;
- example cleanup ledger updates;
- first-mount `world.sav` sentinel verification in a new run;
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
- safe whole-directory recovery-snapshot capture;
- deterministic embark rectangle and site application.

Characterization probes must remain separately selected from ordinary live
test globs.

### Selected live fixture coverage

Use explicitly disposable managed fixtures to prove:

- default deterministic generation from a missing fixture;
- realized seed recording;
- default 2 by 2 embark;
- durable initial save, `world.sav` sentinel, and recovery-snapshot creation;
- a second compatible example reuses without world events;
- a conflicting example discards without saving and reloads the managed save;
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
2. Isolation facets, normalization, observed dirtiness, and run-scoped ledger
   semantics.
3. Project-scoped manifest, ownership marker, and storage layout.
4. Shared private world transition controller and diagnostics.
5. In-process world-generation driver.
6. Embark survey, matching, and deterministic site selection.
7. Quickstart embark, initial save, and durable-save verification.
8. `world.sav` sentinel, exceptional recovery replacement, and recovery
   journal.
9. Run-scoped world fixture lifecycle and example cleanup integration.
10. Focused tests, selected live probes, documentation, and packaging.

Each workstream should receive its own refined contract before implementation.
The generation and recovery-snapshot workstreams are expensive live boundaries
and should not be inferred complete from isolated unit tests.

## Open questions

### Public contract

- Should the `WorldMount` result remain a read-only data record, or should it
  expose carefully bounded query methods?
- Should unknown configuration fields fail immediately to catch misspellings?
- Should fixture recreation be a separate DwarfSpec command, a command-line
  tool, or intentionally manual at first?

### Definition

- How many deterministic generation attempts are allowed when world generation
  rejects valid settings?
- Which accepted use case should drive the first addition beyond the
  first-version site criteria?
- What explicit compatibility rule should govern a later embark-profile
  extension?

### Isolation

- Which initial DwarfSpec mutation helpers can classify their world effects
  more narrowly than `ALL`?
- Which future facet-specific restorers can provide enough evidence to clear
  dirtiness safely?

### Lifecycle

- What should final run cleanup restore when the run began at title?
- May a run begin with an already loaded managed fixture and borrow it?
- Should every `mountWorld()` call be the first stateful command, even when the
  fixture can be reused without a transition?
- At which safe transition boundaries should the managed save image's
  `world.sav` sentinel be checked?
- Should a compatible world remain loaded between separate test-runner
  invocations?

### Storage and compatibility

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

Fixture storage, save sentinels, ownership evidence, collision behavior, and
save-root containment are settled. The next useful design discussion should
settle compatibility fingerprints:

1. the effective raw and mod identity recorded at generation;
2. whether raw identity uses object metadata, source-file content hashes, or
   both;
3. which Dwarf Fortress version or save-format changes invalidate a fixture;
4. whether DFHack version is fixture identity, controller compatibility, or
   diagnostic information only;
5. the exact refusal and explicit-recreation behavior on incompatibility.

These decisions determine whether an owned fixture produced by an earlier
installation remains safe and semantically equivalent to the world definition.
