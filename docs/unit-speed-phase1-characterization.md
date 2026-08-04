# Unit Speed Phase 1 Characterization

This planning record freezes the native behavior and safety decisions required
before implementing `ds.setUnitSpeed(options)` and `ds.setUnitPos(unit_id,
position)`. The source observations apply to DF `53.15` with DFHack `r2` at
commit `425442d4411c29040420af0aacd8d73f13a85545`. Live observations below were
made against the matching installed runtime without invoking `fastdwarf` or
changing its persistent configuration.

## Action timers

The current core-context Lua binding exposes this call directly:

```lua
dfhack.units.setGroupActionTimers(
    unit, 1, df.unit_action_type_group.All)
```

It iterates `unit.actions`, selects actions whose generated `group` metadata
contains `All`, and changes only the timer pointer returned for that action.
The native mutator changes a timer only when its current value is positive.
Zero and negative timers are retained. A positive Attack wind-up `timer1` is
preferred; otherwise its positive recovery `timer2` is used.

The supported mutable members of `All` are:

- `Move.timer`;
- `Attack.timer1` or `Attack.timer2`;
- `HoldTerrain.timer`, `Climb.timer`, `Job.timer`, and `Talk.timer`;
- `Unsteady.timer`, `Dodge.timer`, `Recover.timer`, `StandUp.timer`, and
  `LieDown.timer`;
- `JobRecover.timer`, `PushObject.timer`, and `SuckBlood.timer`;
- `Mount.timer`, `Dismount.timer`, and `HoldItem.timer`; and
- `LoadRangedWeapon.movewait`, `ShootRangedWeapon.movewait`,
  `ThrowItem.movewait`, and `PostShootRecovery.movewait`.

The `All` members `Jump`, `ReleaseTerrain`, `Parry`, `Block`, `ReleaseItem`,
`LeadAnimal`, and `StopLeadAnimal` have no timer pointer in the current helper
and are intentionally unchanged. `None` is not a member of `All` and is also
unchanged. DwarfSpec can call the binding directly from its in-process suite
coroutine; no plugin command is part of the route.

## Eligible target population

The one eligibility predicate for both the default snapshot and explicit IDs
is:

```lua
dfhack.units.isActive(unit) and
    dfhack.units.isAlive(unit) and
    (dfhack.units.isCitizen(unit, false) or
        dfhack.units.isResident(unit, false))
```

This matches the default `dfhack.units.getCitizens()` range: it starts from
`world.units.active`, rejects dead or inactive units, includes citizens and
long-term residents, and passes `include_insane=false` to both classification
functions. The false argument excludes opposed-to-life, undead, crazed,
melancholy, raving, and berserk units through `isSane()`.

The controller will copy and sort IDs at activation. Before every update it
will first require a loaded world and map, then call `df.unit.find(id)` and
reapply the same predicate. A missing, dead, inactive, or newly insane unit is
skipped without mutation. An unloaded world skips the complete update and
must also trigger owned callback cancellation. Since selection is never rerun,
later migrants and residents are not added to the snapshot.

## Job teleport guards and order

All required fastdwarf fields and operations are Lua-visible in the current
core context: `relationship_ids[Dragger]`, `relationship_ids[Draggee]`,
`following`, `counters.unconscious`, `job.current_job`, `pos`, `path.dest`,
`dfhack.maps.canWalkBetween()`, `dfhack.maps.isTileVisible()`,
`dfhack.units.teleport()`, and the `path.path.x`, `path.path.y`, and
`path.path.z` vectors. Lua clears the remaining path by resizing all three
coordinate vectors to zero; `coord_path` itself is not one vector.

Job travel is a no-op unless all of these conditions hold:

- the world and map are loaded and the unit still satisfies the shared target
  predicate;
- neither drag relationship ID is set, `following == 0`, and the unconscious
  counter is zero;
- a current job exists;
- the source and destination coordinates are valid and different;
- the coordinates are walk-connected and the destination is visible; and
- the shared position controller accepts the unit and destination as safely
  reversible.

The caller invokes the shared controller first. It clears `unit.path.path`
only after `dfhack.units.teleport()` returns true. A false return retains the
path. With both speed options enabled, this complete job-teleport attempt
precedes the action-timer call for that unit, matching fastdwarf.

`following` is a reliable signal that this unit follows another. There is no
distinct per-unit "being followed" field: it would require a world scan and is
not a fastdwarf guard. `PushObject` is an action type, not a reliable general
"is pushing" relationship signal. Neither extra guard is claimed.

## Shared position safety and rollback

`dfhack.units.teleport()` requires valid source and destination occupancy,
clears the source standing or grounded occupancy bit, removes projectile state
and its projectile-list entry, may force the unit onto the ground at an
occupied destination, writes destination occupancy, replaces `pos` and
`idle_area`, and moves riders. These effects define the shared controller's
safety boundary.

Before its first accepted move of a unit, the controller must capture the
original `pos` and `idle_area` and validate source occupancy. It must reject:

- projectile units, since projectile-list removal is not reversible by a
  coordinate rollback;
- ridden units and units that are currently riders, since independently
  restoring the complete mount/rider relationship is outside this contract;
- a standing unit moving to a tile whose standing occupancy bit is already
  set, since teleport would change `on_ground` and a return teleport would not
  restore that flag automatically; and
- any source whose standing/grounded occupancy does not agree with the unit's
  current `on_ground` state.

An already-grounded unit may use an occupied destination because its grounded
state does not change. Therefore an occupied destination is not rejected
merely for being occupied, but the shared rollback-safety rule above narrows
the native behavior for a standing arrival. This replaces the earlier blanket
statement that occupied destinations could never add a DwarfSpec guard.

After a successful return teleport, cleanup restores the captured `idle_area`
and verifies `pos`, `idle_area`, `on_ground`, and the source/destination
occupancy bits. Failure to resolve the unit, loss of the map, native teleport
failure, or any verification mismatch is a cleanup failure. A first move that
fails discards its provisional baseline. World unload invalidates map-backed
rollback; it must cancel callbacks immediately, and any outstanding position
baseline prevents cleanup confirmation rather than being silently discarded.

The public guarantee remains owned coordinate rollback, not rewind of paths,
jobs, timers, items, projectiles, riders, RNG, needs, or broader gameplay.
`idle_area`, `on_ground`, and occupancy are verified only because they are
adjacent state directly touched by the native coordinate operation.

## Recurring scheduling and failures

The selected primitive is a one-tick `dfhack.timeout(1, 'ticks', callback)`.
Tick timers use unpaused simulation time, do not fire while paused, resume when
simulation advances, and are cancelled automatically on world unload. The
returned timer ID is the opaque owned handle. The authoritative cancellation
operation and verification signal are:

```lua
dfhack.timeout_active(timer_id, nil)
assert(dfhack.timeout_active(timer_id) == nil)
```

The recurring wrapper stores at most one current handle. On each invocation it
clears that handle before work, verifies that the run and world still qualify,
executes the controller update through `xpcall`, and schedules the next tick
only after success. Cleanup clears controller ownership first, cancels any
current handle, and verifies it inactive. The same run cleanup stack is already
used for assertion failure, command timeout, and explicit abort; world-unload
handling must call the same idempotent cancellation route.

A callback exception must never escape into DFHack's logging-only callback
boundary or reschedule itself. The wrapper catches it once, retains the
traceback, leaves no active handle, and calls one injected host capability that
transitions the active DwarfSpec run to failure and cleanup. This is the bounded
asynchronous-failure route selected for implementation.

## Evidence map

| Requirement | Evidence |
| --- | --- |
| Timer call, positive-only mutation, and member list | `library/LuaApi.cpp`, `library/modules/Units.cpp`, and generated action metadata in `library/xml/df.d_basics.xml` |
| Citizen/resident and sanity semantics | `library/include/modules/Units.h` and `library/modules/Units.cpp` |
| Teleport guards and combined order | `plugins/fastdwarf.cpp` |
| Teleport side effects and rollback constraints | `library/modules/Units.cpp` |
| Tick cadence, unload cancellation, handle cancellation and probe | `docs/dev/Lua API.rst` and the focused live characterization run |
| Terminal cleanup ownership | DwarfSpec cleanup/run lifecycle source and its existing focused unit contracts |
| Installed Lua surface and in-process behavior | Focused live characterization run recorded below |

## Live characterization result

The focused bridge probes ran against DF `v0.53.15 win64 STEAM` and DFHack
`53.15-r2` with a loaded world and map. Every API named by this record was a
live function. `dfhack.units.getCitizens()` returned seven units. A sample
citizen with ID `68` resolved through `df.unit.find(68)`, while the deliberately
invalid ID `-2147483648` resolved to nil. The sample reported citizen=true,
resident=false, active=true, alive=true, and sane=true. Its current tile was
visible and walk-connected to itself.

A temporary synthetic `df.unit` proved the in-process timer route without
touching a world vector. Three `Move` timers produced `1`, `0`, and `-7` from
initial values `50`, `0`, and `-7`. A `Jump` action retained all six seeded raw
data words (`11` through `16`). Attack actions produced wind-up/recovery pairs
`1,40` from `25,40` and `0,1` from `0,35`. The group call returned nil and the
protected multi-action probe succeeded. The seven live target candidates
included two with `idle_area == pos`; none was projectile, ridden, a current
rider, or on the ground. A visible, walkable, unoccupied adjacent tile was
found for unit `68` and was later used by the protected rollback probe below.

The timeout probe returned numeric opaque handles. A handle was active before
`dfhack.timeout_active(handle, nil)` and inactive afterward; its callback did
not fire. An exploratory probe initially supplied the cancellation arguments
to the wrong function, then immediately recovered handle `294375` with the
supported cancellation call. The corrected probe used handle `297404`.
A separate terminal verification reported both handles inactive, the callback
still unfired, and the world and map still loaded. No plugin command, world
lifecycle command, or persistent configuration change occurred.

The cadence probe preserved an inherited paused state of true and scheduled
handle `300197` for one simulation tick. After 1.2 seconds it had fired zero
times, remained active, and the game remained paused. After temporarily
unpausing, it fired exactly once within 1.5 seconds and became inactive. Cleanup
restored the inherited paused state and removed temporary probe state. A
separate terminal command verified the handle inactive, pause=true, temporary
state absent, and world/map still loaded.

The reversible teleport probe then paused the game and revalidated citizen
`68` at source `48,57,131` with matching `idle_area`, standing occupancy,
no projectile, rider, ridden, or drag state, and an unchanged path signature.
Destination `47,56,131` was loaded, visible, walk-connected, and had neither
standing nor grounded unit occupancy. A synthetic invalid-position teleport
returned false and retained both invalid `pos` and `idle_area` unchanged.

The real outbound teleport returned true, changed `pos` and `idle_area` to the
destination, retained `on_ground=false`, cleared source standing occupancy, set
destination standing occupancy, and retained the complete path signature. The
protected return teleport also returned true. Cleanup restored the exact
original `pos`, `idle_area`, `on_ground`, complete source and destination
occupancy words, path signature, and inherited paused state. An independent
terminal probe reconfirmed the source standing bit set, destination standing
and grounded bits clear, path vectors empty with the original destination and
goal values, pause=true, and world/map loaded. An initial preflight attempt had
misread `coord_path` as one vector, but it aborted before any teleport and its
cleanup independently verified unchanged position, idle area, and pause.

Focused existing DwarfSpec cleanup tests supplied the lifecycle half of the
scheduling evidence. Ten targeted runs produced 32 successes, zero failures,
zero errors, and zero pending. They establish cleanup after suite/assertion
failure, external command timeout, explicit abort, lease expiry, callback or
arming fault, and stale callback delivery. They also establish unload-event
mapping and listener cleanup. Native DFHack tick timers are automatically
cancelled on world unload; the future position controller must still report
cleanup failure if an owned map-backed baseline survives that unload. These
tests do not claim that not-yet-implemented unit state is already restored.
