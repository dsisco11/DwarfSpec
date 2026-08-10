# Representative runtime capability classification

This planning record classifies the framework dependencies used by the five
representative verified commands. Stateful capabilities are constructed once
for an assembled run and passed to command owners as class-like instances.
Stateless helpers may be imported directly by command modules.

| Concern | Classification | Owner and boundary |
| --- | --- | --- |
| Interaction-target resolution | Stateful, run-scoped | `InteractionTargetResolver` owns access to the current mount context and resolves only subjects belonging to that run. |
| Click dispatch and render observation | Stateful, run-scoped | `ClickRuntime` combines the run's resolver, mounted input ingress, and command-context render observation. |
| Map-view reads, writes, and origin conversion | Stateful, run-scoped | `MapViewRuntime` owns the assembled host accessors and screen-origin enum used by the reversible setter. |
| Save-game host, loader, and unloader access | Stateful, run-scoped | `SaveGameRuntime` exposes one cohesive host-transition boundary while the command definition retains workflow ordering and policy. |
| Rendered-text matching | Stateful, run-scoped | `SearchRuntime` combines the current mount context with the run's rendered-text matcher. |
| Text-search normalization and rectangle operations | Stateless | `driver.commands.text_search` contains dependency-free value validation and geometry helpers. Command modules import it directly; the composition root passes its explicitly loaded instance to `SearchRuntime` so loader-local sentinel identity remains coherent. |
| Overlay registration | Stateful transaction | The existing `OverlayRegistrationTransaction` remains the capability boundary and is injected directly without another wrapper table. |

Capability services expose runtime interaction only. Command definitions keep
normalization, stage orchestration, receipts, verification, claims, cleanup,
registration, and public binding. No service imports the assembled `ds` facade
or host execution internals.
