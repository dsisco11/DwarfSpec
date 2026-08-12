# Built-in command registration

Verified built-in commands have one ownership and registration model. Each
public command is represented by one class-like module under
`dwarfspec.driver.builtins`. The owner exposes:

- `definition()`, which returns the validated immutable command definition;
- `arguments(...)`, which adapts the public call into a request table and an
  optional trailing command-options table; and
- `binding()` only when the command is installed on a non-`ds` surface.

An owner contains command policy: normalization, readiness, execution,
verification, retries, claims, receipts, cleanup, workflow steps, and result
projection. Runtime capability objects contain only cohesive host interaction.
The composition root constructs both and does not reproduce either concern.

`BuiltinCommandRegistrar` is the only authority that registers these owners.
It validates the owner contract, registers the definition with the injected
runner, rejects duplicate definitions and bindings, prevents replacement of an
existing namespace member, and installs exactly one runner-backed closure. The
default binding is `ds[definition.name]`. Qualified subject commands declare an
explicit `subject` surface and an unqualified public method name.

Registration is an explicit ordered array. Filesystem discovery, table-key
iteration, side-effect registration during `require`, and command-local
namespace mutation are intentionally unsupported. This keeps registration
order reviewable and ensures a command cannot be loaded without its public
binding or bound without its validated definition.

## Verified command inventory

| Public binding | Owner module | Runtime capability |
| --- | --- | --- |
| `ds.wait_frames` | `wait_frames` | `WaitRuntime` |
| `ds.wait_ticks` | `wait_ticks` | `WaitRuntime` |
| `ds.await` | `await` | `WaitRuntime` |
| `ds.awaitEvent` | `await_event` | `WaitRuntime` |
| `ds.isGamePaused` | `is_game_paused` | `GameQueryRuntime` |
| `ds.getGameSpeed` | `get_game_speed` | `GameQueryRuntime` |
| `ds.getTick` | `get_tick` | `GameQueryRuntime` |
| `ds.getTime` | `get_time` | `GameQueryRuntime` |
| `ds.getSaveDirectoryName` | `get_save_directory_name` | `GameQueryRuntime` |
| `ds.hasFocus` | `has_focus` | `GameQueryRuntime` |
| `ds.current_run` | `current_run` | `RunQueryRuntime` |
| `ds.root` | `root` | `MountQueryRuntime` |
| `ds.get` | `get` | `MountQueryRuntime` |
| `ds.inspect` | `inspect` | `MountQueryRuntime` |
| `ds.capture_view_tree` | `capture_view_tree` | `MountQueryRuntime` |
| `ds.capture_screen` | `capture_screen` | `CaptureRuntime` |
| `subject:getFocusList` | `subject_get_focus_list` | `SubjectQueryRuntime` |
| `subject:raw` | `subject_raw` | `SubjectQueryRuntime` |
| `ds.search` | `search` | `SearchRuntime` |
| `ds.click` | `click` | `ClickRuntime` |
| `ds.getViewPos` | `get_view_pos` | `MapViewRuntime` |
| `ds.setViewPos` | `set_view_pos` | `MapViewRuntime` |
| `ds.mountSaveGame` | `mount_save_game` | `SaveGameRuntime` |
| `ds.stage_overlay_registration` | `stage_overlay_registration` | `OverlayRegistrationTransaction` |
| `ds.registerCleanup` | `register_cleanup` | cleanup registration service |

## Remaining direct facade operations

The registrar inventory is deliberately limited to verified commands. Legacy
state setters, pointer/input operations, mount lifecycle operations, and unit
simulation controls remain direct facade operations until their own verified
command migrations. They must not be added to the registrar as callback
bundles: their eventual owners must follow the same one-file owner contract.
