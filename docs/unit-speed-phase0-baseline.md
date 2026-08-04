# Unit Speed Phase 0 Baseline

This planning record freezes the implementation ownership, native reference
behavior, and pre-production-change evidence for `ds.setUnitSpeed(options)` and
`ds.setUnitPos(unit_id, position)`.
It supports Phase 0 of [unit-speed.todo](unit-speed.todo).

## Checkout baseline

The baseline was captured on 2026-08-04 before any unit-speed production,
declaration, test, package, or live-automation files were changed.

- DwarfSpec branch: `unit-speed-command`.
- DwarfSpec commit: `f13a49def44f23bd7beb71d7482bdc852ddc0bab`.
- DwarfSpec package: `dwarfspec 0.2.2-1`.
- `git status --short`: empty. The committed planning file was present, and
  there was no pre-existing DwarfSpec worktree or index change to preserve.
- Reference DFHack commit: `425442d4411c29040420af0aacd8d73f13a85545`.
- Reference native version: DF `53.15`, DFHack `r2`.
- The sibling DFHack checkout had one unrelated pre-existing change,
  `depends/dfhooks`; the relevant fastdwarf and Units sources were unchanged.

## Contract ownership ledger

| Obligation | Implementation owner | Verification and evidence owner |
| --- | --- | --- |
| Public `ds.setUnitSpeed(options)` command and void return | Phase 6.1 public composition and Phase 6.2 declarations | Phase 6.3 source/package contract and Phase 8 final audit |
| Public `ds.setUnitPos(unit_id, position)` command, `dwarfspec.UnitPosition`, and void return | Phase 5.2 behavior and Phase 6 public composition/declarations | Phases 5.5, 6.3, 7, and 8 final evidence |
| Synchronous explicit positioning while paused without pause/TPS mutation | Phase 5.2 explicit command behavior | Phases 5.5 and 7.2 |
| `dwarfspec.UnitSpeedOptions` with exactly `fast_actions`, `teleport_jobs`, and optional `unit_ids` | Phase 3.1 normalization and Phase 6.2 declarations | Phase 3.4 validation tests and Phase 6.3 declaration/runtime comparison |
| At least one enabled behavior | Phase 3.1 option validation | Phase 3.4 focused validation tests |
| Independent and combined behavior flags | Phase 4 fast actions and Phase 5 teleportation | Phases 4.2, 5.2, 5.3, and 7.2 |
| Teleport before fast actions when both are enabled | Phase 5.2 combined behavior | Phase 5.3 deterministic-order tests |
| Default target snapshot | Phase 3.2 target capture | Phase 3.4 unit tests and Phase 7.2 live evidence |
| Explicit nonempty, dense, unique integer ID array | Phase 3.1 validation | Phase 3.4 input coverage and Phase 6.2 declaration fixtures |
| Activation-time resolution and eligibility | Phase 3.2 target capture | Phase 3.4 invalid/ineligible-ID coverage |
| Retain copied IDs and re-resolve before every update | Phase 3.2 controller state plus Phases 4.1 and 5.1 updates | Phases 3.4, 4.2, and 5.3 |
| Skip absent or newly ineligible captured targets | Phase 3.2 lifecycle policy plus Phases 4.1 and 5.1 updates | Phases 3.4, 4.2, and 5.3 |
| One active controller per example | Phase 3.3 ownership | Phase 3.4 rejection and consecutive-example tests |
| Pause and TPS remain independent | Phase 3.3 activation and the existing game-state command | Phases 3.4, 7.2, and 8.1 |
| Automatic deactivation and verified cleanup | Phase 2.3 cleanup integration | Phases 2.4 and 7.3 terminal-path evidence |
| One shared teleport implementation and first position plus helper-coupled `idle_area` baseline per moved unit | Phase 5.1 shared unit-position controller | Phases 5.5, 7.2, 7.3, and 8.4 |
| Coordinate rollback for explicit placement and job travel | Phase 5.1 cleanup restoration | Phases 5.5 and 7.2 live coordinate verification |
| Cancel recurring job travel before coordinate restoration | Phase 5.1 LIFO cleanup ordering | Phases 5.5 and 7.3 terminal-path verification |
| `unit_position_active` cleanup ownership probe | Phase 5.1 shared controller and authoritative cleanup probe | Phases 5.5 and 7.3 terminal reports |
| Callback faults become one bounded run failure | Phases 1.4 and 2.1 | Phase 2.4 callback-failure and isolation tests |
| User documentation | Phase 8.1 | Phase 8.4 final implementation audit |
| Source and installed package delivery | Phase 6.1 composition and rockspec automatic module discovery | Phases 6.3 and 8.3 |

## Exclusion ledger

| Exclusion | Enforcement owner | Final evidence owner |
| --- | --- | --- |
| No fastdwarf plugin invocation or configuration | Native adapters in Phases 4 and 5 call DFHack Lua APIs directly | Phases 6.3 and 8.4 |
| No `fastdwarf/config` persistent-data access | No persistence capability is injected into the controller | Phase 8.4 scoped-source audit |
| No `debug_turbospeed` or fastdwarf mode 2 | Phase 4.1 limits acceleration to group action timers | Phases 7.2 and 8.4 |
| No CLI switch, Busted tag behavior, default, preset, arbitrary filter, or public scheduler | Phase 2.2 keeps scheduling private; no controller/configuration surface owns these features | Phase 8.1 documentation and Phase 8.4 audit |
| No dynamic target expansion | Phase 3.2 snapshots IDs once | Phases 3.4 and 7.2 |
| No promise to rewind paths, jobs, timers, or broader gameplay | Phase 5.1 restores only coordinates owned by the shared controller | Phases 7.3, 8.1, and 8.4 |
| No shipped managed-world integration | No production owner in this checklist | Phase 8.1 documents only the future seam |

## Behavior distinctions

`ds.setGameSpeed(tps)` controls the simulation target in ticks per second and
restores the inherited target during example cleanup. It does not accelerate a
specific unit action or move a unit.

`fast_actions=true` repeatedly sets supported positive action timers for the
captured eligible units to one through
`dfhack.units.setGroupActionTimers(unit, 1, df.unit_action_type_group.All)`.
It does not change skills, jobs, attributes, needs, labor assignments, game TPS,
or unsupported action records. The exact supported timer members remain a
Phase 1 characterization requirement.

`teleport_jobs=true` attempts to move a captured eligible unit to its current
job destination after the native guards pass. When both behaviors are enabled,
teleportation is attempted first and action timers are accelerated second.

Fastdwarf mode 2 is separate native global turbo behavior implemented by
`df.global.debug_turbospeed`. It affects all units and is excluded from this
feature.

Stopping the recurring controller, dropping retained IDs, restoring coordinates
captured by the shared unit-position controller, and verifying that no callback
or position baseline remains are reversible DwarfSpec ownership operations.
Paths, timers, completed jobs, produced items, RNG state, needs, and other
simulation consequences are not restored.

`ds.setUnitPos(unit_id, position)` resolves one integer unit ID and a typed map
coordinate, teleports through the shared controller, and returns no value. It is
not restricted to the citizen/resident population used by `setUnitSpeed`.
Before the first successful explicit or job-travel teleport of a unit, the
controller captures its original coordinate and helper-coupled `idle_area`.
Later moves share that baseline, and cleanup restores and verifies both values.
Phase 1 must characterize and constrain adjacent native state that coordinate
rollback cannot safely reverse.

## Targeting rules

- Omitted `unit_ids` snapshots the currently eligible citizen and long-term
  resident IDs once, in deterministic ID order, during activation.
- Explicit `unit_ids` must be a nonempty dense array of unique integers. Every
  ID must resolve to a unit satisfying the same eligibility predicate during
  activation. Resolution and eligibility define validity; there is no separate
  positive-number restriction.
- The controller copies flags and IDs and retains no borrowed unit object.
- Each update processes the captured IDs in stable order, resolves each unit
  again, and skips it without mutation when it is absent or newly ineligible.
- Migrants, residents, visitors, hostiles, animals, or other units that were not
  in the activation snapshot are never added dynamically.
- A second activation is rejected while the example owns an active controller.
  Cleanup must prove the controller inactive before a later example can create
  another one.

The exact Lua-visible predicate for active, living, sane citizens and long-term
residents remains isolated to Phase 1 characterization.

## Native fastdwarf reference

The reference is
`D:\CODE\DFHack\DFHack\plugins\fastdwarf.cpp` at the DFHack commit recorded
above.

Fastdwarf stores per-site `fast` and `tele` integers in
`fastdwarf/config`. On each plugin update, it enumerates citizens and attempts
teleportation before setting group action timers. Mode 1 calls
`Units::setGroupActionTimers(..., 1, All)`; mode 2 writes the separate
`debug_turbospeed` global.

Fastdwarf's job teleport returns without mutation when any of these conditions
holds:

- the unit is dragging another creature or is being dragged;
- the unit follows another unit;
- the unit is unconscious;
- the current position or path destination is invalid;
- the current position already equals the destination;
- the unit has no current job;
- the current position and destination are not walk-connected; or
- the destination is unrevealed.

It then calls `Units::teleport(unit, unit->path.dest)`. A false result leaves the
remaining path intact. A true result is followed by clearing `unit->path.path`.
The source contains no separate pushing, being-followed, or occupied-destination
guard.

The teleport helper:

- requires valid source and destination occupancy records;
- clears the unit's former standing or grounded occupancy flag;
- removes unit projectile state and its projectile-list entry;
- forces the arriving unit onto the ground when another unit is already standing
  at the destination;
- sets destination standing or grounded occupancy;
- updates `unit.pos` and `unit.idle_area`; and
- moves riders, including babies, to the destination.

Phase 1 owns live confirmation of Lua call shapes, eligibility, timer members,
simulation-tick cadence, cancellation verification, asynchronous failure
delivery, and every Lua-visible teleport guard. Documentation-only pushing and
being-followed claims remain explicitly unconfirmed.

## Repository seam map

- Public command binding: add a focused sibling of
  `src/dwarfspec/driver/commands/game_state.lua` for unit speed and unit position;
  keep game TPS behavior in the existing module unchanged.
- Simulation implementation: place target selection, native unit operations,
  teleport eligibility, shared coordinate ownership and rollback, controller
  state, and recurring update execution in focused modules beneath
  `src/dwarfspec/driver/simulation/`. Both public commands must use the same
  position controller. The exact remaining split is chosen during implementation
  to avoid empty or single-use abstractions.
- Host boundary: extend
  `src/dwarfspec/host/execution/run_capabilities.lua` with only the private
  recurring scheduling, opaque-handle cancellation, scheduled-state, and
  failure-reporting operations required by the driver.
- Composition: `src/dwarfspec/ds.lua` loads and injects the focused driver
  command. It must not contain a second inline implementation and driver modules
  must not import `dwarfspec.host`.
- Protocol and declarations: reserve `setUnitSpeed` and `setUnitPos` in
  `src/dwarfspec/protocol/configuration/schema.lua`; declare both void commands,
  the option type, and `dwarfspec.UnitPosition` in `src/ds.d.lua`.
- Unit tests: command/controller/native-adapter tests belong under
  `tests/unit/driver`; capability lifecycle tests belong under
  `tests/unit/host/execution`; schema reservation remains with the schema tests.
- Declaration tests: valid and invalid fixtures belong under
  `tests/declarations` and run through `tools/Check-SourceDeclarations.ps1`.
- Live tests: focused native behavior belongs under `tests/automation` and must
  report terminal cleanup independently from gameplay restoration.
- User documentation: `docs/writing-tests.md` owns usage and lifecycle guidance;
  `docs/command-line.md` receives only applicable public-command summary text,
  not a unit-speed CLI switch; `docs/architecture.md` owns namespace boundaries;
  `CHANGELOG.md` changes only when release policy requires it.
- Packaging: the root rockspec automatically discovers Lua modules beneath
  `src/`, installs `bin/dwarfspec`, and explicitly excludes repository test
  directories with `copy_directories = {}`.

## Baseline verification

Focused unit command:

```powershell
$rockTree = Join-Path (Get-Location) '.luarocks'
$env:LUA_PATH = & luarocks path --tree $rockTree --lr-path
$env:LUA_CPATH = & luarocks path --tree $rockTree --lr-cpath
$bustedRockDir = (& luarocks show busted 2.3.0-1 --tree $rockTree --rock-dir).Trim()
$bustedRunner = Join-Path $bustedRockDir 'bin/busted'
lua $bustedRunner --defer-print -o plainTerminal `
    tests/unit/driver/commands/game_state_spec.lua `
    tests/unit/host/execution/run_capabilities_spec.lua `
    tests/unit/host/execution/cleanup_spec.lua `
    tests/unit/host/service/schemas_spec.lua `
    tests/unit/controller/configuration/config_spec.lua `
    tests/unit/host/environment/extensions_spec.lua
```

Result: 33 successes, 0 failures, 0 errors, and 0 pending in 0.032 seconds.
The configuration and extension suites exercise the project-command reservation
schema; the service schema suite covers run and cleanup reporting structures.
There is no separate declaration unit suite; declaration fixtures are exercised
by the declaration checker below.

Complete unit command and result:

```powershell
.\tools\Run-UnitTests.ps1
```

Result: 905 successes, 0 failures, 0 errors, and 0 pending in 3.109 seconds.

Static commands and results:

```powershell
.\tools\Check-Lua.ps1
.\tools\Check-SourceDeclarations.ps1 -Mode Valid
.\tools\Check-SourceDeclarations.ps1 -Mode Invalid
```

- Lua 5.4.6 syntax and formatting checks passed for 339 files.
- Valid source declaration fixtures passed with no diagnostics.
- Invalid source declaration fixtures produced the expected diagnostics,
  including the required `dwarfspec.TestBed`,
  `dwarfspec.ModuleComponentSource`, `component_imports`, and
  `testbed_unknown_strategy.lua` markers.

Every command exited zero. The initial baseline commands left the worktree
clean. The corrected authoritative focused run occurred after this task created
the planning ledger and therefore observed only the task-owned modification to
`docs/unit-speed.todo` and untracked `docs/unit-speed-phase0-baseline.md`. A
superseded exploratory Busted filter selected zero tests; the direct-file
focused command above is the authoritative focused result.

## Recorded live and package procedures

The complete source-checkout live command is:

```powershell
.\tools\Run-AutomationTests.ps1
```

The focused command for the future unit-speed live specification is:

```powershell
.\tools\Run-AutomationTests.ps1 `
    --test-glob tests/automation/unit_speed_live_spec.lua
```

The wrapper reads `DFHACK_ROOT` from the local `.env`, resolves
`dfhack-run.exe`, and otherwise defaults to `tests/automation/*.lua`. Live
results are not baseline evidence for Phase 0; Phases 1 and 7 own the required
native characterization and qualification runs.

The established package procedure is:

1. Run `tools/Publish.ps1`. It validates the versioned rockspec name, lints the
   rockspec, and builds `dist/dwarfspec-0.2.2-1.all.rock` with no dependency
   installation.
2. Inspect the rock archive manifest and verify the expected `src` modules,
   `src/ds.d.lua`, and portable command are present, while tests and native
   libraries are absent.
3. Install the exact generated artifact into an empty LuaRocks tree and execute
   command and module smoke checks without checkout fallback.
4. Run the live DFHack package proof through the installed command.

Phase 8 owns fresh publication, exact archive inspection, empty-tree installed
contract verification, and installed live proof after implementation.
