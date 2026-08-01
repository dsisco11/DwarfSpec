# Source Organization Phase 0 Baseline

Recorded 2026-07-31 from branch `source-file-reorganization` at commit
`441bcb1fc5ba3f9edee082023d001cf47a4b2d5d`. No production source moves were
performed during this baseline.

## Checkout and inventory

- Worktree was clean before the baseline except for the already-tracked source
  organization planning changes; no unrelated worktree or index changes were
  modified.
- Production inventory: 92 Lua files beneath `src/dwarfspec/`.
- Unit inventory: 57 Lua specs beneath `tests/unit/`.
- Live inventory: 16 Lua specs beneath `tests/automation/`.
- The dependency/path scan covered 497 `require()`, `loadfile()`, and entry-path
  references across source, tests, launcher, and tooling.
- `src/dwarfspec/layout.lua` currently returns source/installed paths for
  `bootstrap`, `status`, `recover`, `recover_executor`, `scheduler_status`,
  `run_query`, `abort`, `acknowledge`, and `probe`.

## Source-checkout baselines

| Check | Result |
|---|---|
| `tools/Run-UnitTests.ps1` | 637 successes / 0 failures / 0 errors / 0 pending; 1.281 seconds. |
| `tools/Check-Lua.ps1` | Lua 5.4.6 syntax and formatting passed for 220 files. |
| LuaLS valid declaration fixture | No problems found; exit 0. |
| LuaLS invalid declaration fixture | Six expected bounded warnings; exit 1. |

The declaration invocation used LuaLS 3.18.2-dev from the installed
`sumneko.lua-3.18.2-win32-x64` extension with
`tests/declarations/source.luarc.json`. It checked only the source checkout;
no installed rock or packaged declaration tree was loaded.

## Focused live baselines

| Scope | Result | Cleanup |
|---|---|---|
| Component render tracking | 4 successes / 0 failures | `cleanup_confirmed=true` |
| Ordinary widget mounting | 8 successes / 0 failures | `cleanup_confirmed=true` |
| Native-screen mounting | 0 successes / 3 errors | `cleanup_confirmed=false` |
| Pointer/native input routing | 0 successes / 1 failure / 1 error | `cleanup_confirmed=false` |
| Event waits | 2 successes / 0 failures | `cleanup_confirmed=true` |
| Save-game same-save command | 1 success / 0 failures | `cleanup_confirmed=true` |
| Scheduler recovery and cleanup | 5 successes / 0 failures | `cleanup_confirmed=true` |

The native-screen and native-input failures share the external installed
DwarfUI hotkey overlay error at `dwarfui/hotkeys/model.lua:120`: field `invoke`
was nil during overlay rescan. The input scope also recorded an independent
fullscreen-registration assertion failure. These are recorded baseline
failures, not source-organization regressions.

## Full live and multi-process baselines

The full non-destructive live sweep observed 30 successes before reaching the
same native-input/native-screen overlay failures. It recorded one failure and
four errors, then aborted during the overlay suite with
`cleanup_confirmed=false`. The executor was subsequently recovered through the
public `recover-executor` command.

`tools/Run-MultiProjectIntegration.ps1` failed in its first iteration while
the alpha service project waited for its FIFO hold (`alpha FIFO hold`, 10.016
seconds). That run's failed alpha suite reported `cleanup_confirmed=true`, but
the concurrent beta run remained active until it was explicitly aborted. The
post-recovery status was verified as executor idle, queue 0, and quarantine
none. This integration timeout is recorded as a pre-existing baseline failure.

## Baseline boundary

Phase 0 is complete as a characterization baseline, including its known live
and integration failures. No source files were moved or behavior changed.
