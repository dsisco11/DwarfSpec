# Source Organization Proposal

## Status

Proposed. This document defines a source-tree cleanup; it does not authorize
implementation or change any public DwarfSpec behavior.

## Summary

Organize production modules by execution boundary and role: external
controller, in-process host, run-scoped driver, shared protocol, and shared
support. Keep a small set of stable top-level entry points, move shared wire
contracts into a runtime-neutral namespace, and make the unit-test tree mirror
the production tree.

The recommended top-level production layout is:

```text
src/dwarfspec/
  cli.lua                 # stable external-command facade
  ds.lua                  # stable run-scoped driver facade
  layout.lua              # stable package-layout facade
  controller/             # external Lua process
  host/                   # DFHack core Lua process
  driver/                 # live-test interaction implementation
  protocol/               # data contracts shared across processes
  support/                # small runtime-neutral utilities
```

This layout reflects the four responsibilities already documented in
`docs/architecture.md`: the external command, the in-process host, the
run-scoped driver, and their shared deterministic reporting contracts.

## Why change the current layout

The current tree contains 92 production Lua modules and about 20,000 lines.
Forty-two modules are flat under `src/dwarfspec/`, while 46 more are grouped
under the broad `automation/` name. The result has several problems:

- a filename does not reveal whether it executes externally or inside DFHack;
- `automation/` combines entry scripts, scheduling, persistence, lifecycle,
  DFHack adapters, result contracts, and game operations;
- the flat root mixes CLI configuration, mounting, rendering, native widget
  traversal, public enums, reporting, and process execution;
- related modules are separated, such as `runner.lua` and the automation
  service modules it controls;
- generic names such as `project.lua` exist in both the root and
  `automation/`, with different responsibilities;
- source and installed paths are repeated as string literals in `ds.lua`,
  `layout.lua`, host entry scripts, tests, and integration helpers; and
- the largest files remain difficult to navigate even if their surrounding
  directory is renamed.

The cleanup should improve ownership and dependency direction, not merely
reduce the number of files visible in one directory.

## Design rules

### Execution boundary and role come first

A module that directly uses `df`, `dfhack`, or DFHack-provided modules belongs
under `host/` or `driver/`. A module that invokes `dfhack-run`, reads the local
project, or formats terminal output belongs under `controller/`. A module used
on both sides must be pure Lua and belongs under `protocol/` or `support/`.

### Dependencies point inward

The intended dependency direction is:

```text
cli.lua -> controller -------> protocol -> support
host entry scripts -> host ---> protocol -> support
                        |
                        +-----> driver ---> protocol -> support

ds.lua (composition root) ---> host
                         +---> driver
```

`controller/` must not require `host/` or `driver/`. The controller may select
and invoke host entry scripts by path, but it must not load their code into the
external interpreter. `protocol/` and `support/` must not depend on either
runtime. `driver/` may use DFHack but must not own run scheduling or service
persistence. As an explicit temporary exception, the root `ds.lua` facade is
the composition root that may load both host services and driver modules.
Modules beneath `driver/` must not require modules beneath `host/` directly.

### Stable entry points stay shallow

Keep these existing module names during the cleanup:

- `dwarfspec.cli` for the installed executable;
- `dwarfspec.layout` for source-versus-installed path resolution; and
- `dwarfspec.ds` for host construction of the run-scoped `ds` object.

They should become thin facades over the organized implementation. Retaining
them avoids coupling the executable, host bootstrap, consumers, and package
layout to the internal directory structure.

No other internal module path should be treated as public without evidence
that a consumer uses it. Before removing an old path, search the repository,
documentation, packaged archive, and known consumer projects. When external
use cannot be ruled out, leave a one-release forwarding module that returns
the replacement module.

### One concept, one name

Use names that distinguish the two current project concepts:

- `controller/discovery/project.lua` describes the project selected by the
  CLI; and
- `host/environment/project_environment.lua` loads project configuration and
  modules in the DFHack process.

Likewise, reserve `host/entrypoints/` for scripts invoked directly through
`dfhack-run`; reusable host modules must not be placed there.

## Proposed production tree

```text
src/dwarfspec/
  cli.lua
  ds.lua
  layout.lua

  controller/
    configuration/
      config.lua
      dotenv.lua
    discovery/
      project.lua
    execution/
      process.lua
      runner.lua
    reporting/
      diagnostic_formatter.lua
      report.lua
    result_store.lua

  host/
    entrypoints/
      abort.lua
      acknowledge.lua
      bootstrap.lua
      cancel.lua
      discard.lua
      event_read.lua
      probe.lua
      recover.lua
      recover_executor.lua
      run_query.lua
      scheduler_status.lua
      status.lua
    execution/
      busted_lifecycle_adapter.lua
      cleanup.lua
      coroutine_scheduler.lua
      file_suite_identity.lua
      host.lua
      output_handler.lua
    service/
      projects.lua
      scheduler.lua
      service.lua
      snapshots.lua
    environment/
      extensions.lua
      lfs_adapter.lua
      project_environment.lua
      system_adapter.lua
    diagnostics/
      base_screen_focus_comparisons.lua
      diagnostics.lua
      focus_diagnostics.lua
      problem_source.lua
    game/
      base_screen_focus_guard.lua
      overlay_registration.lua
      save_game_load.lua
      save_game_mount.lua
      save_game_unload.lua

  driver/
    commands/
      await_event.lua
      save_game_load.lua
      save_game_unload.lua
      text_search.lua
    input/
      input_states.lua
      mouse_buttons.lua
      pointer_anchors.lua
      pointer_adapter.lua
      pointer_spaces.lua
    mount/
      component.lua
      mount_adapters.lua
      mount_context.lua
      native_attachment.lua
      overlay_mount.lua
    render/
      native_render_observer.lua
      render_instrumentation.lua
      render_tracker.lua
    subjects/
      interaction_target.lua
      lua_view_adapter.lua
      native_game_ui_path.lua
      native_widget_adapter.lua
      overlay_registry_adapter.lua
      subject.lua
      subject_paths.lua
      subject_requests.lua
      subject_sources.lua
      native_resolution_failure_kinds.lua
      native_resolution_stages.lua
    screen_origins.lua
    state_change_events.lua

  protocol/
    events.lua
    schemas.lua
    configuration/
      error_formats.lua
      schema.lua
      settings.lua
    diagnostics/
      focus.lua
    enums/
      event_types.lua
      owner_kinds.lua
      result_policies.lua
      result_states.lua
      runner_failure_kinds.lua
      run_states.lua
      scheduler_failure_kinds.lua
      test_statuses.lua

  support/
    glob.lua
    identity_labels.lua
    immutable_enum.lua
    project_paths.lua
```

`ds.d.lua` remains at `src/ds.d.lua`. It is a declaration surface rather than
an installed implementation module and should not be mixed into the runtime
hierarchy.

## Current-to-target mapping

| Current area | Target area | Notes |
|---|---|---|
| `config.lua`, `dotenv.lua` | `controller/configuration/` | These load external process configuration and environment values. |
| `config_schema.lua`, `settings.lua`, `error_formats.lua` | `protocol/configuration/` | Both the controller and host validate the same consumer configuration contract. |
| `glob.lua` | `support/` | Glob compilation is pure and is used by both controller and host project discovery. |
| root `project.lua` | `controller/discovery/` plus `support/project_paths.lua` | Keep controller project discovery external and extract only the pure path operations needed across runtimes. |
| `runner.lua`, `process.lua`, `runner_failure_kinds.lua` | `controller/execution/` and `protocol/enums/` | Runner failure data stays runtime-neutral because the host emits it. |
| `report.lua`, `diagnostic_formatter.lua` | `controller/reporting/` | Formatting belongs to the external presentation boundary. |
| automation entry scripts | `host/entrypoints/` | These remain standalone scripts callable by absolute path. |
| `automation/host.lua`, lifecycle and coroutine modules | `host/execution/` | This is embedded Busted execution, not the service model. |
| automation scheduler, service, projects, and snapshots | `host/service/` | Snapshots project mutable service registries and therefore remain host-owned. |
| automation project and extension loaders | `host/environment/` | Rename the host-side `project.lua` to remove ambiguity. |
| automation diagnostic, focus-capture, and problem-source modules | `host/diagnostics/` | Keep host capture separate from external formatting and the pure focus wire validator in `protocol/diagnostics/`. |
| automation save-game and registration modules | `host/game/` | These perform DFHack state transitions. |
| `component.lua`, mount modules | `driver/mount/` | These own the mounted resource lifecycle. |
| subject, native lookup, and view adapter modules | `driver/subjects/` | These implement selection and retained identity. |
| render modules | `driver/render/` | These implement invalidation and completed-render observation. |
| `commands/` | `driver/commands/` | Built-in commands are part of the run-scoped driver. |
| `automation/pointer_adapter.lua` | `driver/input/` | Pointer movement is interaction behavior, not run orchestration. |
| event, schema, state, policy, and cross-runtime failure vocabulary | `protocol/` | These values cross the controller/host boundary. Split focus-diagnostic capture from its pure wire validator before moving events. Driver-only enums stay with the driver. |
| immutable enum and identity-label helpers | `support/` | Keep this directory small and dependency-free. |

`result_store.lua` remains in `controller/`, but its current dependency on
host-owned project state must be removed first. Extract the pure path
normalization it needs into `support/project_paths.lua`; do not move the host
project registry into the controller. Split `events.lua` so its wire contract
and validation are pure protocol code while focus capture remains under
`host/diagnostics/`. `schemas.lua` then remains protocol code, and
`snapshots.lua` remains under `host/service/` because it projects mutable host
registries.

## Path and loading strategy

Physical moves currently affect more than `require()` calls. Several modules
are deliberately loaded with `loadfile()` so the host receives fresh code and
so source checkouts and installed LuaRocks trees behave the same. Preserve
that behavior.

Before moving modules:

1. Extend `dwarfspec.layout` into the single authority for source and installed
   paths to host entry scripts.
2. Add a small internal loader that accepts a canonical module name and derives
   its source-tree path. Remove paired arguments such as
   `('dwarfspec.component', '/src/dwarfspec/component.lua')`.
3. Keep cache-bypass behavior explicit for modules that must be reloaded in
   DFHack. Do not replace deliberate `loadfile()` calls with ordinary
   `require()` calls as part of the directory cleanup.
4. Update source-identity classification in `host/diagnostics/problem_source`
   to recognize the organized tree without exposing absolute local paths.
5. Add a package-layout test that resolves every registered entry point and
   every driver module from both a source checkout and an installed-tree
   fixture.

The entrypoint scripts need a tiny duplicated bootstrap that derives the Lua
module root before normal module loading is available. That exception is
intentional; the list of downstream host paths should not be duplicated.

## Large-module decomposition

Directory moves and file decomposition should be separate commits. First move
cohesive modules without changing their behavior. Once the new dependency
boundaries are enforced, split the five current hotspots:

- `ds.lua` (about 2,000 lines): retain construction and public command binding
  in the facade; move mount, pointer, event, game-state, and wait command
  implementations into driver command modules.
- `automation/host.lua` (about 1,400 lines): separate run assembly, Busted
  execution, example lifecycle, module-environment audit, and transport
  publication.
- `automation/scheduler.lua` (about 1,100 lines): separate queue selection,
  lease/quarantine policy, and transition recording while keeping one service
  state owner.
- `mount_context.lua` (about 1,100 lines): separate resource ownership,
  subject resolution, command execution diagnostics, and cleanup verification.
- `runner.lua` (about 1,000 lines): separate command construction, process
  transport, polling, timeout/abort handling, and result interpretation.

Each extraction must introduce a named responsibility with its own direct
tests. Avoid generic dumping grounds such as `utils.lua`, `helpers.lua`, or
`common.lua`.

## Test organization

After production paths stabilize, mirror them beneath `tests/unit/`:

```text
tests/unit/
  controller/
  host/
  driver/
  protocol/
  support/
```

Update `tools/Run-UnitTests.ps1` before moving any unit specs. Remove Busted's
`--no-recursive` option so its normal recursive discovery includes every
nested spec beneath `tests/unit/`. Add an inventory assertion or a nested
sentinel spec so the repository gate fails if recursive discovery is disabled
again or silently executes only the top-level files.

Keep live suites under `tests/automation/`, destructive live suites under
`tests/destructive/`, and multi-process scenarios under `tests/integration/`.
Those directories describe execution cost and environment, which is useful to
operators and test scripts.

Rename unit specs to match the target module path, for example:

- `tests/unit/mount_context_spec.lua` becomes
  `tests/unit/driver/mount/mount_context_spec.lua`;
- `tests/unit/automation_service_spec.lua` becomes
  `tests/unit/host/service/service_spec.lua`; and
- `tests/unit/config_spec.lua` becomes
  `tests/unit/controller/configuration/config_spec.lua`.

Move tests after their production modules so failures remain attributable.
Do not move checked-in protocol fixtures or generated `.test-results` merely
to make the tree look symmetric.

## Implementation sequence

1. Record the current unit, syntax, package, and focused live baselines.
2. Add dependency-boundary tests and centralize source/installed path
   resolution without moving files.
3. Split host-aware validation from the pure event and configuration
   contracts, then create `protocol/` and `support/` and update all callers.
4. Create `controller/`, retaining the three stable root facades.
5. Move the run-scoped implementation into `driver/`.
6. Replace `automation/` with `host/`, moving entry scripts last so external
   invocation remains continuously testable.
7. Enable recursive Busted discovery, then mirror unit-test paths and update
   direct `loadfile()` fixtures.
8. Update architecture and contributor documentation, publish a package, and
   inspect the archive for the exact expected module tree.
9. Remove forwarding modules only after the compatibility window and consumer
   audit are complete.
10. Decompose the large modules in small, separately verified changes.

Every move should use `git mv` and update one cohesive dependency cluster.
Do not combine this work with public API changes, new test-runner UI behavior,
TestBed implementation, or selector redesign.

## Verification gates

The cleanup is complete only when all of the following are independently
demonstrated:

- all unit tests pass from the source checkout;
- Lua syntax and repository formatting checks pass;
- dependency-boundary tests enforce the complete allowed-import matrix:
  `controller/` imports only controller, protocol, and support modules;
  `host/` imports host, driver, protocol, and support modules; `driver/`
  imports only driver, protocol, and support modules; `protocol/` imports only
  protocol and support modules; and `support/` imports only support modules;
- the dependency audit recognizes only the documented root `ds.lua`
  composition exception for loading both host and driver modules;
- the unit runner recursively discovers nested specs and verifies its expected
  test inventory;
- the CLI `help`, `list`, `run`, status, abort, recovery, and inspection paths
  resolve the new host entrypoint locations;
- focused live tests cover component mounting, native-screen mounting,
  pointer input, events, save-game commands, cleanup, and scheduler recovery;
- the full non-destructive live suite passes with cleanup confirmation kept
  distinct from test success;
- the LuaRocks package builds and its archive contains every new module and no
  retired implementation paths, except intentional forwarding modules;
- an installed-package smoke run proves that paths are not accidentally
  resolving back to the source checkout;
- declarations still validate against both source and installed layouts;
- documentation contains no stale internal paths; and
- `git diff --check` passes with unrelated worktree state preserved.

## Risks and mitigations

### Hidden path coupling

Tests and host adapters use direct `loadfile()` paths. Centralize those paths
first and add source/installed layout tests before any bulk move.

### Runtime boundary violations

Pure-Lua unit tests can accidentally load a DFHack-only module through a new
dependency. Add a static import audit and isolated-load tests for `protocol/`
and `controller/`.

### Stale installed modules

Moving modules can leave old files in a development LuaRocks tree. Validate in
a fresh temporary tree and inspect the produced rock; do not infer installed
correctness from source tests.

### Compatibility ambiguity

Internal module names have not been declared as a supported API, but consumers
may still require them. Search known consumers and use forwarding modules when
uncertain. Document that only the root facades and the run-scoped `ds` surface
are stable after the compatibility window.

### Review noise

Moves plus behavior edits obscure history. Keep path-only moves, require-path
updates, test moves, and later decompositions in distinct commits.

## Follow-up work

Create a separate implementation plan to remove the temporary `ds.lua`
composition exception. That plan should evaluate moving driver-facing
save-game workflows, overlay registration, and interaction diagnostics under
`driver/`, with host scheduling, cleanup, project-environment, and service
capabilities supplied through explicit injected interfaces.

The follow-up plan must:

- inventory every host module currently loaded by `ds.lua`;
- define the narrow capabilities the driver actually needs from each module;
- place run-scoped game operations according to ownership rather than their
  historical `automation/` location;
- preserve fresh `loadfile()` behavior and source-versus-installed loading;
- add boundary tests proving modules beneath `driver/` do not import
  `host/`; and
- provide incremental migration and compatibility gates without changing the
  public `ds` API.

Until that plan is approved and implemented, `ds.lua` remains the sole
documented composition root allowed to load both namespaces.

## Decision

Adopt the execution-boundary-and-role organization above. Do not retain
`automation/` as the general home for all live-test code: it hides the
important distinction between host orchestration and the driver that a test
uses. Preserve shallow facades and source/installed loading semantics, then
enforce the new boundaries with tests before decomposing large files.
