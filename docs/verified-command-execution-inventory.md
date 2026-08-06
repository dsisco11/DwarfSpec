# Verified command execution migration inventory

## Purpose and authority

This document freezes the pre-conversion inventory required by section 1 of
`verified-command-execution.todo`. The proposal remains authoritative. This
ledger records the current public contract, assigns every surface a single
migration destination, and names the validation boundary that must prevent an
old execution path from surviving conversion.

Vocabulary is used exactly as approved by the proposal:

- command kinds are `QUERY`, `ASSERTION`, `ACTION`, `STATE_SETTER`, `WORKFLOW`,
  and `FIXTURE`;
- every initial definition uses `ONCE`; `EXPLICIT_RETRY_SAFE` is reserved for
  the synthetic qualification definition until another definition satisfies
  the full stable-key, idempotency, attempt-receipt, and cleanup-before-retry
  proof contract;
- non-workflow intrinsic policy is `PRIMARY_OBSERVATION` for
  queries/assertions, `EXECUTION_RECEIPT` when dispatch or framework-owned
  action evidence is the strongest truthful guarantee, and `CALLBACK` for
  state setters, fixtures, and actions whose effect is independently
  observable;
- workflow verification is expressed by verified steps and a pure result
  projector, not by assigning one non-workflow intrinsic policy.

## Public command migration ledger

Signatures and returns below are the current declarations. `nil` means the
existing declaration intentionally specifies no public result. All mutators
are assigned `ONCE`. The validation boundary for every row is the shared
definition conformance suite plus the named family-focused suite; native
adapter behavior additionally retains the smallest applicable live case.
Unless a row says otherwise, the current command performs no render wait and
registers no cleanup. “Direct native” means the injected DFHack/native-game
capability, not a separate command invocation.

| Public command and current return | Current behavior and direct dependencies | Destination contract | Validation boundary |
| --- | --- | --- | --- |
| `current_run()` -> run context | Read-only facade access to the active Busted/run environment. | `QUERY`, `PRIMARY_OBSERVATION`; registry-backed context query. | Registry/facade and lifecycle-context units. |
| `wait_frames(count, options?)` -> integer | Scheduler wait for raw frames; uses wait settings/options. | `ASSERTION`, `PRIMARY_OBSERVATION`; finite shared deadline. | Wait conformance, scheduler units, live raw-frame case. |
| `wait_ticks(count, options?)` -> integer | Scheduler wait for unpaused simulation ticks. | `ASSERTION`, `PRIMARY_OBSERVATION`; finite shared deadline. | Wait conformance, scheduler units, live tick case. |
| `await(description, query, options?)` -> observed value | Polls a caller read-only query once per frame. | `ASSERTION`, `PRIMARY_OBSERVATION`; pending/ready/fatal outcomes. | Wait conformance and observation-result units. |
| `awaitEvent(event, options?)` -> occurrence | Arms native event listener, optionally triggers, then scheduler-waits; currently permits no command-local timeout when omitted. | `ASSERTION`, `PRIMARY_OBSERVATION`; finite command default replaces unlimited behavior. | Event/wait units and synchronous-event live case. |
| `isGamePaused()` -> boolean | Direct native pause read. | `QUERY`, `PRIMARY_OBSERVATION`. | Game-state conformance and focused units. |
| `getGameSpeed()` -> integer | Direct native TPS read. | `QUERY`, `PRIMARY_OBSERVATION`. | Game-state conformance and focused units. |
| `getTick()` -> integer | Direct loaded-world tick read. | `QUERY`, `PRIMARY_OBSERVATION`. | Game-state conformance and loaded-world live case. |
| `getTime()` -> integer | Direct DFHack millisecond clock read. | `QUERY`, `PRIMARY_OBSERVATION`. | Game-state conformance and focused units. |
| `getSaveDirectoryName()` -> string | Direct loaded-save identity read. | `QUERY`, `PRIMARY_OBSERVATION`. | Game-state conformance and loaded-save live case. |
| `hasFocus(path)` -> boolean | Reads current DFHack focus strings. | `QUERY`, `PRIMARY_OBSERVATION`. | Focus conformance and focused units. |
| `getViewPos(origin?)` -> position | Reads native map viewport and geometry. | `QUERY`, `PRIMARY_OBSERVATION`. | View-position units and live origin cases. |
| `root(options?)` -> Subject | Resolves current mount/source identity and retains a subject. | `QUERY`, `PRIMARY_OBSERVATION`; stable mount/source identity. | Mount/subject conformance and native/overlay units. |
| `get(control_path, options?)` -> Subject | Resolves exact component/native path through mount adapters. | `QUERY`, `PRIMARY_OBSERVATION`. | Mount/subject resolution units and representative live paths. |
| `inspect(view?)` -> table | Resolves a live subject and returns a stable diagnostic snapshot. | `QUERY`, `PRIMARY_OBSERVATION`. | Subject conformance and adapter-focused units. |
| `search(query, area?)` -> rectangle or nil | Reads final screen cells; ordinary miss is successful nil. Uses text-search, mount/source, render-buffer adapters. | `QUERY`, `PRIMARY_OBSERVATION`; nil remains an unambiguous successful observation. | Search conformance, focused units, representative render case. |
| `capture_view_tree(name, options?)` -> table | Captures/deduplicates bounded invocation-owned evidence; no cleanup. | `QUERY`, `PRIMARY_OBSERVATION`; artifact result. | Capture units, result formatting, package declaration. |
| `capture_screen(name, options?)` -> capture | Captures/deduplicates bounded screen-cell evidence; no cleanup. | `QUERY`, `PRIMARY_OBSERVATION`; artifact result. | Capture units, result formatting, representative render case. |
| `setGamePaused(paused)` -> boolean | Writes pause state, snapshots baseline, registers callback cleanup. | `STATE_SETTER`, `CALLBACK`, `ONCE`; receipt cleanup at owner lifetime. | State-setter conformance, cleanup units, live readback/restoration. |
| `setGameSpeed(tps)` -> integer | Writes TPS, snapshots baseline, registers callback cleanup. | `STATE_SETTER`, `CALLBACK`, `ONCE`. | State-setter conformance, cleanup units, live readback/restoration. |
| `setTurboSpeed(enabled)` -> boolean | Writes process-global turbo flag and registers restoration. | `STATE_SETTER`, `CALLBACK`, `ONCE`. | State-setter conformance, cleanup units, live readback/restoration. |
| `setViewPos(position, origin?)` -> position | Uses view-position adapter; snapshots/restores viewport. | `STATE_SETTER`, `CALLBACK`, `ONCE`. | View-position edge units and live origin/restoration cases. |
| `setUnitPos(unit_id, position)` -> nil | Resolves unit/map occupancy, mutates position, shares baseline controller cleanup. | `STATE_SETTER`, `CALLBACK`, `ONCE`; receipt includes stable unit and occupancy state. | Unit-position conformance, partial-effect/cleanup units, live case. |
| `setUnitSpeed(options)` -> nil | Configures recurring unit-speed operation and shared position controller cleanup. | `STATE_SETTER`, `CALLBACK`, `ONCE`; product progress remains optional caller verification. | Unit-speed conformance, scheduler/cleanup units, live case. |
| `exitToMainMenu()` -> exited directory or nil | Multi-screen native save-unload sequence; deliberately not restored. | `WORKFLOW`; named verified steps and pure public-result projector. | Workflow conformance, title/save focused units, live transition. |
| `mountSaveGame(directory)` -> string | Multi-screen save selection/load sequence; may first unload another world. | `WORKFLOW`; named verified steps and pure public-result projector. | Workflow conformance, save-load units, live exact-save transition. |
| `mount(component, options?)` -> Subject | Creates/shows owned component/screen, selects source, registers mount/subject cleanup, waits for render. | `WORKFLOW`; fixture-like creation occurs in verified non-workflow steps. | Workflow and mount conformance, ownership/cleanup units, live mount. |
| `mountNativeScreen()` -> Subject | Attaches to borrowed current screen without creating/dismissing it; registers detach cleanup. | `WORKFLOW`; verified attachment steps. | Workflow/mount conformance and borrowed-screen live case. |
| `unmount()` -> nil | Releases current owned or borrowed mount and retained subjects. | `WORKFLOW`; verified absence/ownership terminal state. | Workflow/mount cleanup units and representative live case. |
| `redraw(view?, options?)` -> any | Invalidates current mounted screen; waits for completed render by default. `{wait=false}` returns after invalidation. | `ACTION`, `CALLBACK`, `ONCE`; verify a later generation when waiting and accepted invalidation otherwise. | Action/render conformance, wait true/false units, live generation case. |
| `move_pointer(view?, anchor?, ...)` -> coordinates | Resolves subject/grid/pixel/world target; may recenter; writes pointer/camera and registers restoration. | `ACTION`, `CALLBACK`, `ONCE`; internal placement operation for composites. | Pointer conformance, geometry/cleanup units, coordinate-space live cases. |
| `hover(view?, anchor?, ...)` -> coordinates | Composes pointer placement and render settling. | `ACTION`, `CALLBACK`, `ONCE`; internal step, not nested public mutation. | Pointer/action conformance and live hover/render case. |
| `input(keys, subject?)` -> integer | Dispatches native input and waits for screen settling. | `ACTION`, `CALLBACK`, `ONCE`; verifies dispatch receipt and settling without claiming product consumption. | Input conformance, ignored-input units, representative live ingress. |
| `mouseInput(button, action?)` -> integer | Dispatches mouse state at virtual pointer; persistent states register restoration. | `ACTION`, `CALLBACK`, `ONCE`; verifies receipt, pointer consistency, and transient restoration. | Mouse conformance, transient cleanup units, live ingress. |
| `mouseWheel(options, subject?)` -> integer | Optional subject placement, discrete wheel dispatch, final render wait. | `ACTION`, `CALLBACK`, `ONCE`; verifies input receipt, pointer consistency, and final render. | Mouse conformance, composite-operation units, live render case. |
| `click(view, button?)` -> integer | Subject placement plus mouse click and render wait; restores pointer, not product effects. | `ACTION`, `CALLBACK`, `ONCE`; verifies input receipt, pointer consistency, and render boundary. | Click conformance, ignored/unexpected-screen units, live case. |
| `type(text, subject?)` -> integer | Sends supported string keycodes, optionally through mounted subject. | `ACTION`, `CALLBACK`, `ONCE`; verifies dispatch receipt and settling without claiming product consumption. | Input conformance, unsupported/ignored input units, live case. |
| `viewport(width, height)` -> any | Resizes owned mounted host and waits for layout/render. | `STATE_SETTER`, `CALLBACK`, `ONCE`; mount lifetime owns restoration/removal. | Mount/render conformance, ownership units, live resize case. |
| `stage_overlay_registration(source, name)` -> table | Copies/stages overlay source, changes config/registration, and registers multi-part lifecycle cleanup. | `FIXTURE`, `CALLBACK`, `ONCE`; effect receipt and claims bind only after confirmed staging. | Fixture conformance, partial-effect/claims/cleanup units, integration live case. |

`setTurboSpeed`, `setUnitSpeed`, `setUnitPos`, and command-family bindings under
`driver/commands` are public even where `ds.lua` receives them through binders
rather than spelling a second function body. Conversely, enum/constants on
`ds` are declaration surface but are not command invocations.

The direct dependency map behind the row summaries is:

- waits/events: `driver/commands/wait.lua`, `await_event.lua`, the injected
  coroutine scheduler, event adapter, and wait settings;
- game/save/view state: `driver/commands/game_state.lua`,
  `view_position.lua`, `save_game_load.lua`, `save_game_unload.lua`,
  `title_menu.lua`, native-game adapters, and the current callback cleanup
  registry;
- units: `driver/commands/unit_position.lua`, `unit_speed.lua` and
  `driver/simulation/unit_position_controller.lua`,
  `unit_speed_controller.lua`;
- mount/subjects/render/capture/search: `driver/commands/mount.lua`,
  `capture.lua`, `text_search.lua`, the `driver/mount/*` ownership,
  resolution, and adapter services, `driver/subjects/subject.lua`, and the
  render/capture capabilities composed in `ds.lua`;
- pointer/input: `driver/commands/pointer.lua`, `input.lua`,
  `driver/input/pointer_adapter.lua`, native input simulation, current mount
  resolution, render waiting, and callback cleanup; and
- overlay fixture staging: the `ds.lua` staging implementation, filesystem,
  overlay/configuration adapters, and callback cleanup registry.

## Subject fluent surface

`Subject:click`, `Subject:hover`, `Subject:move_pointer`,
`Subject:mouseWheel`, `Subject:input`, `Subject:type`, and `Subject:redraw`
delegate to the identically named public definitions and return the
same subject for fluency. Their command kind, intrinsic policy, execution
policy, deadline, event, and validation boundary are therefore the matching
ledger row; the binder must preserve the fluent return without creating a
parallel command definition.

`Subject:inspect` and `Subject:search` delegate and preserve the matching query
result.
`Subject:getFocusList()` is an additional `QUERY`/`PRIMARY_OBSERVATION` command surface
returning a detached string list; it migrates with focus queries.
`Subject:text()` is a derived `QUERY`/`PRIMARY_OBSERVATION` over the inspect definition
and returns string or nil. `Subject:raw()` is a `QUERY`/`PRIMARY_OBSERVATION` over
current mount ownership and returns the exact adapted object. Both must use
nested read-only invocation when called inside a command callback and must not
become unobserved direct escape paths. Subject conformance tests are the
validation boundary for all three additional methods.

## Definition-source and project-command inventory

Current built-in behavior is divided among `driver/commands/await_event.lua`,
`capture.lua`, `game_state.lua`, `input.lua`, `mount.lua`, `pointer.lua`,
`save_game_load.lua`, `save_game_unload.lua`, `text_search.lua`,
`title_menu.lua`, `unit_position.lua`, `unit_speed.lua`, `view_position.lua`,
and `wait.lua`. Each moves to one immutable definition per ledger row under the
command registry. Domain adapters remain dependencies; none may publish command
success, own a second deadline, or register callback cleanup directly after
conversion.

`host/environment/extensions.lua` discovers both `tests/dwarfspec/config.lua`
and `tests/dwarfspec/commands.lua`, validates `commands` as a map of bare
functions in `protocol/configuration/schema.lua`, and stores `{callback,
source}`. The repository contains four bare-callback fixture modules:

- `tests/framework/minimal_project/tests/dwarfspec/commands.lua` exports
  `consumer_identity`;
- the alpha, beta, and gamma service-project fixtures each export
  `project_identity`.

All four are read-only `QUERY`/`PRIMARY_OBSERVATION` definitions with `ONCE` policy.
They, the loader, schema fixtures, reserved-name tests, declarations, and
package fixtures migrate to immutable definitions. Bare callbacks must fail at
load time once the coordinated conversion checkpoint is reached. Project
definition schema tests plus multi-project framework isolation are the
validation boundary; there is no legacy callback adapter.

## Cleanup, ownership, lifecycle, and result touchpoints

| Current touchpoint | Current role | Migration destination and validation boundary |
| --- | --- | --- |
| `host/execution/cleanup.lua` and `ds.lua` example cleanup registry | Stores callbacks and executes remaining cleanup around examples. | Replace with `CleanupRegistrationService`, transaction journal, planner, verifier, and owner-specific finalization; lifecycle/cleanup qualification. |
| `driver/commands/game_state.lua`, `view_position.lua`, simulation controllers, pointer adapter, and mount adapters/services | Capture baselines and register closure-backed cleanup at disparate points. | Emit immutable effect/cleanup receipts; runner registers transactions and claims after confirmed effects; command-family plus cleanup conformance. |
| `driver/mount/mount_cleanup_verification.lua` and mount ownership services | Release subjects and verify mount cleanup through mount-specific paths. | Domain verification capability beneath common cleanup transactions; mount/cleanup focused tests. |
| Host Busted/lifecycle hooks and scheduler finalization | Trigger example cleanup and materialize current terminal report. | Explicit service-run, suite-execution, test-attempt, and command-invocation ownership; ordering tests at every lifecycle level. |
| `protocol/events.lua` and `protocol/enums/event_types.lua` | Current command started/finished and cleanup started/failed/finished schemas, journal copies, cursor reads. | Coordinated event revision with identities, stages, attempts, transaction dispositions, owner attribution, bounded evidence, and child ancestry; protocol/cursor suites. |
| `protocol/schemas.lua` | Validates active, retained, read-only, and terminal reports including `cleanup_confirmed`. | Validate journal and equal owner projections at service/suite/test levels; schema fixtures and retained-read suites. |
| Host execution run state/report assembly | Owns active report, event journal, terminal result, cleanup requirement/confirmation, quarantine decision. | Journal is historical authority; fold live state and materialize projections before owner-finished events; lifecycle/quarantine suites. |
| `controller/execution/result_interpreter.lua`, `run_poller.lua`, `run_recovery.lua`, and `result_store.lua` | Interpret terminal cleanup state, consume cursor reads, recover/abort, persist retained results. | Consume revised version atomically without a dual schema; protocol negotiation, persistence, recovery, and equality suites. |
| `controller/reporting/report.lua` and transport client | Format cleanup state/events, retained reads, status, and quarantine diagnostics. | Format command trees, attempts, cleanup transactions/dispositions, and bounded evidence; controller golden/transport fixtures. |
| `cleanup_confirmed` producers and consumers | Host terminal reporting produces it; schemas, controller interpretation/reporting/recovery and framework tests consume it. | Keep authoritative as a summary derived from complete transaction outcomes, never as a replacement ledger; terminal negative and cleanup-confirmed integration cases. |

Quarantine currently arises when cleanup cannot be confirmed or executor/run
recovery cannot safely continue. The destination keeps this decision in the
service executor using journal-backed unconfirmed/failed evidence; command and
domain adapters cannot clear or bypass it.

The production `cleanup_confirmed` site list is frozen as
`host/execution/run_lifecycle.lua`, `host/service/scheduler/admission.lua`,
`host/service/scheduler/transitions.lua`, `host/service/service.lua`,
`host/service/snapshots.lua`, `protocol/events.lua`, `protocol/schemas.lua`,
`controller/command_line.lua`, `controller/execution/result_interpreter.lua`,
`controller/execution/run_recovery.lua`, and
`controller/reporting/report.lua`. Tests and JSON protocol fixtures which
produce or assert the field migrate with their owning production module; they
are validation evidence, not additional authorities.

### Current result and event field ledger

The coordinated schema revision must preserve or deliberately supersede every
field below. `protocol/schemas.lua` is the validator and
`host/service/snapshots.lua` is the principal active/retained producer.

| Surface | Current fields | Producers and consumers | Destination and validation boundary |
| --- | --- | --- | --- |
| Active/terminal `dwarfspec.run.v2` snapshot | `schema`, `protocol_version`, `service_instance_id`, `project_id`, `run_id`, `generation`, `state`, `terminal`, `queue_position`, `submitted_at_ms`, `activated_at_ms`, `queue_wait_ms`, `current_repeat`, `current_test`, `counts`, `totals`, `last_sequence`, `queue_lease`, `execution_lease`, `owner_kind`, `acknowledged`, `discarded`, `terminal_reason`, `cleanup_confirmed`, `cleanup_reason`, `mount_cleanup_verified`, `turbo_speed_active`, `unit_speed_cleanup_verified`, `unit_speed_active`, `unit_position_active`, `owned_position_count`, `host_error`, `failures` | Produced by service scheduler state, `host/execution/run_lifecycle.lua`, `host/service/snapshots.lua`, and `host/service/service.lua`; consumed by schemas, controller runner/transport/reporting/recovery/command line, and tests. | Retain run identity/state/timing/count/lease/failure fields; add authoritative journal-derived service/suite/test cleanup projections and command trees in the coordinated schema. Validate active, terminal, transport, retained, and persisted equality. |
| Retained history entry/envelope | Entry: `run_id`, `project_id`, `project_name`, `project_root`, `generation`, `state`, `terminal`, `submitted_at_ms`, `activated_at_ms`, `finished_at_ms`, `cleanup_confirmed`, `acknowledged`, `discarded`, `log_line_count`; envelope: `schema`, `protocol`, `service_loaded`, `service_instance_id`, `runs` | Produced by `host/service/snapshots.lua` and service reads; consumed by controller transport/reporting and retained-run tests. | Preserve summary compatibility and make cleanup summary derive from retained transaction projections; retained-read schema/equality tests. |
| Run inspection/cursor transport | `schema`, `protocol`, service/run identity, `service_loaded`, `found`, optional project metadata, `snapshot`, `events`, `after_sequence`, `last_sequence` | Produced by `host/service/service.lua` from the run snapshot and journal; consumed by controller `run_poller.lua`, `runner.lua`, `transport_client.lua`, and reporting. | Carry the revised snapshot and owner-tagged journal atomically; cursor/stale/ahead/retained consistency suites. |
| Controller `dwarfspec.result.v2` envelope | `schema`, `state`, `terminal`, `exit_code`, `project_root`, `selection.identities`, `events`, optional `error`, `submitted_at`, `activated_at`, `finished_at`, `queue_wait_ms`, optional service/run identity, and `host_report` | Built/interpreted by controller `runner.lua`, `result_interpreter.lua`, `command_builder.lua`; persisted by `result_store.lua`; formatted by reporting/command line. | `host_report` gains equal service/suite/test cleanup projections and command evidence while the outer controller contract remains coherent; result-state, persistence, formatting, and source/package fixtures. |
| Event journal | Common identity/sequence/time/type fields plus current `run.*`, `repeat.*`, `test.*`, `problem.recorded`, `command.started`, `command.finished`, `diagnostic.recorded`, `cleanup.started`, `cleanup.failed`, `cleanup.finished`, and `scheduler.blocked` payloads | Produced through `protocol/events.lua` by lifecycle, scheduler, command observer, and cleanup; consumed by service cursor/retained reads, controller polling/reporting/persistence, and protocol fixtures. | Coordinated event revision adds invocation/parent/owner/stage/attempt and cleanup transaction/owner/disposition/evidence fields. The journal remains historical authority; event-schema, ordering, cursor, folding, and projection-equality suites. |
| Service/scheduler snapshots and quarantine | Service/scheduler schema/protocol/instance/package identity, active run/project, queue, projects, and quarantine `{active, reason?, run_id?, generation?}` | Produced by `host/service/snapshots.lua`, admission/transitions/service; consumed by transport client, status/command line/reporting, recovery, and scheduler tests. | Preserve scheduler ownership and expose quarantine decisions backed by unresolved cleanup journal evidence; scheduler/admission/recovery/status suites. |

Lifecycle hooks are concretely owned by `host/execution/run_lifecycle.lua` and
the Busted integration composed by the host executor. Transport production and
consumption are concretely owned by `host/service/service.lua`,
`controller/execution/runner.lua`, `run_poller.lua`, `transport_client.lua`,
`result_interpreter.lua`, `command_builder.lua`, `result_store.lua`,
`controller/command_line.lua`, and `controller/reporting/report.lua`.

## Configuration and timeout inventory

`protocol/configuration/settings.lua` accepts positive integer
`settings.wait.frame_budget` and `settings.wait.timeout_ms`; the latter is
currently propagated into wait/scheduler behavior and examples/tests. Several
wait commands also accept per-call `timeout_ms`, and `awaitEvent` explicitly
documents an unlimited default when omitted. Existing configuration fixtures,
declarations, example projects, command option declarations, and package copies
that mention these fields are migration touchpoints.

The concrete source/documentation owners are `src/ds.d.lua`,
`driver/commands/await_event.lua`, `save_game_load.lua`,
`save_game_unload.lua`, `wait.lua`, `host/entrypoints/bootstrap.lua`,
`host/execution/coroutine_scheduler.lua`,
`host/service/scheduler/admission.lua`,
`host/service/scheduler/request_validation.lua`,
`protocol/configuration/settings.lua`, `docs/configuration.md`,
`docs/writing-tests.md`, and `docs/architecture.md`. The repository and four
framework-project `tests/dwarfspec/config.lua` fixtures, their configuration
unit tests, and live timeout/wait fixtures are the corresponding examples and
validation sites. Generated `.test-results` and package-output copies are
evidence/artifacts and must not be edited as source.

The destination precedence is the proposal's finite command timeout chain:
invocation option, definition default, then framework command default. Cleanup
uses its separate finite precedence. `settings.wait.timeout_ms` remains only
during bounded migration compatibility and is removed as a command default at
the consolidation checkpoint. `timeout_ms=false` and every unlimited path are
then rejected. Configuration/schema/declaration checks cover shape and
precedence; scheduler clock tests cover one absolute deadline; final searches
prove the fallback and unlimited forms are absent.

The only existing public asynchronous invalidation contract found is
`redraw(..., {wait=false})` (including `Subject:redraw`). It must remain an
explicit overload whose intrinsic guarantee stops at accepted invalidation.
No other current public command is assigned implicit `wait=false` semantics.

## Compatibility decision

`current_run()` is the one undocumented public-return exception: it exists in
`ds.lua` but not `src/ds.d.lua` or existing public documentation. The migration
decision is to preserve its current run-context return, add its declaration
during public API conversion, and route the read through the registry-backed
query without changing the value shape. This is a compatibility/documentation
correction, not permission to redesign the return.

No other undocumented or internally inconsistent public return requires a
behavior change before conversion. The declarations and facade agree on the
remaining supported returns listed above. Two deliberate weak types (`redraw` and `viewport` return
`any`) and two declared nil returns (`setUnitPos`, `setUnitSpeed`) are preserved
until a separately approved API decision changes them. Successful nil from
`search` remains a valid query miss; workflow no-op nil from `exitToMainMenu`
remains distinct from failure. Fluent subject methods continue returning their
subject even when the underlying public command returns another value.

## Acceptance-criterion traceability

| Proposal acceptance area | Implementation-plan destination | Required proof boundary |
| --- | --- | --- |
| Single runner, finite deadlines, definitions, read-only callback capabilities, `ONCE`, retry-safe proof, intrinsic/caller verification, stage diagnostics, and receipt distinctions | Sections 2-8, 14-16, and 21 | Registry/runner qualification, conformance matrix, declaration checks, final old-path searches. |
| Nested read-only ancestry, workflow definitions/steps/state/projector, and no public mutator recursion | Sections 7, 8, 15, 18-20 | Child-event and workflow qualification plus representative integrations. |
| Effect-driven registration, attempt cleanup, owner lifetimes, claims, serialization, opaque references, resource-index invariants, and graph/planner rules | DAG prerequisite and sections 9-12, 17, 20 | Graph, resource-index, effect-registration, conflict, retry, cleanup-order, and quarantine suites. |
| One cleanup service, public `registerCleanup`, mandatory receipts/verification, manual execution, abandonment, finite independent retryable cleanup, and fresh cancellation | Sections 10-13 | Cleanup service/executor conformance at command, test, suite, and service ownership. |
| Owner finalization ordering, durable journal, unique terminal projections, cursor/retained/persisted equality, service-run verification children, and quarantine | Sections 11-13 and 23 | Protocol, lifecycle, persistence, controller, transport, retained-read, and terminal live evidence. |
| Signature/return compatibility, definition-only project commands, thin facade, removal of parallel paths and unlimited/fallback timeouts | Sections 1, 6, 14, 16-22 | This ledger, declarations, project-loader fixtures, source dependency checks, package checks, and removal searches. |
| Managed-fixture integration, risk-based migration, documentation, packaging, and exhaustive qualification | Sections 15, 20, 22, and 23 | Representative cases, focused/full/static/package evidence, and terminal live proof with cleanup confirmation. |

Every public command appears in the public ledger or the subject-only ledger.
Every present cleanup/result/configuration/protocol surface appears in the
touchpoint tables. Later conversion reviews must reconcile against this file;
adding a public command or fixture requires adding a row before it can be
considered migrated.
