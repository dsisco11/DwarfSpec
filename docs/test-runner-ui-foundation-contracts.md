# DwarfSpec test-runner UI foundation contracts

This document is the source-backed design contract for the foundation section of
`test-runner-ui.todo`. The Penpot specimens are visual references; this file
records the behavior and ownership that cannot be communicated reliably by a
single static state.

## Sources

- Official inventory: DFHack stable documentation, **In-game UI library**.
- Installed render implementation:
  `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets.lua` and
  `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets\`.
- Frame implementation:
  `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui.lua`.
- Premium texture selection:
  `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\textures.lua`.
- Installed Premium game artwork:
  `G:\Steam\steamapps\common\Dwarf Fortress\data\art\`.
- Runner capability contracts: `src/dwarfspec/automation/`,
  `src/dwarfspec/ds.lua`, and `src/dwarfspec/cli.lua`.

The stable documentation inventory used to seed the checklist contains 28
classes. The locally installed DFHack 53.15-r1 loader exports 27 of them.
`RadioButton` is the only documented class with no installed implementation.
Its Penpot page records that source block instead of inventing a rendering
contract.

## Penpot rendering rules

- All game text uses `font.baseGame` at the established 12 px game-text
  size.
- Every foreground, background, border, selection, and status solid color is
  linked to the existing DF palette. The specimens introduce no literal design
  colors.
- Premium graphics-mode tiles are authoritative whenever the installed render
  pen supplies a `tile`. Imported official game and DFHack texture sheets are
  exposed as reusable complete-row components. Their source pixels are raster
  artwork and are not replaced with palette-colored approximations.
- The installed Premium PNGs contain no transparent pixels. Their dark
  `#1C1C1C` surface is preserved because DFHack's texture loader preserves the
  source alpha; it is not keyed out in the runtime.
- The `COLOR_BLACK` library color is the Premium-rendered black pen and resolves
  to that exact `#1C1C1C` texture surface. Widget, component, Panel, Window,
  and runner surfaces link directly to this palette asset; no separate
  panel-background token is used. The actual Penpot page Canvas Background
  property is pure `#000000` and is not a widget fill.
- Per-cell Premium texture crops are private implementation details of composed
  frame masters, not public rendering primitives.
- Character-only, non-printable, and extended visual symbols use the existing
  CP437 atlas assets. Printable ASCII emitted literally by the installed
  widget remains `font.baseGame` text; no Unicode or newly drawn substitute is
  permitted.
- Each complex specimen and its variants live on a dedicated dark-canvas page
  under one clearly named top-level board.
- A specimen only shows states supported by the installed widget. Unsupported
  requested states are annotated instead of invented.
- `Widget` is an abstract, non-visual contract and therefore has no standalone
  component master.

## Official widget coverage

The authoritative per-widget rendering matrix is maintained once in
`docs/dfhack-widget-rendering-reference.md`. The Penpot coverage board maps
each row from that reference to one of:

- a dedicated linked component page;
- an explicitly annotated pre-existing component;
- the non-visual `Widget` contract; or
- the source-blocked `RadioButton` record.

This document owns product and component contracts, not duplicate rendering
descriptions.

## Component architecture

The dependency direction is:

1. official DFHack widgets;
2. custom generic components;
3. DwarfSpec domain components;
4. reusable screen panels;
5. the workspace mockup and its controller/view-model.

Each component owns one visual or interaction responsibility. It does not own
status aggregation, flake classification, sorting policy, evidence capture,
editor launching, or cross-panel synchronization. Those are supplied by the
runner adapter or workspace controller.

Repeated borders, labels, dividers, scrollbars, and interaction states are
component instances. A complex component is extracted when it is reused, has
independent state, owns scrolling/clipping, contains repeated children, or is
shown in several workspace states. One-off headings, explanatory copy, footer
counts, stack separators, and complete workspaces stay local.

## Product and data ownership

The viewer has four explicit selection levels:

| Selection | Owns | Does not own |
| --- | --- | --- |
| Run | lifecycle state, progress, aggregate counts, selection scope, elapsed time, repeat configuration, reproduce command, and run-level cleanup/infrastructure outcome | one test's assertion details |
| File or suite | explorer expansion, supplied aggregate status, scoped rerun, and suite identity | recomputing aggregate status in the tree |
| Test attempt | behavior outcome, failure/error record, duration, repeat index, source location, and evidence availability | raw-log retention policy |
| Command or event step | command name, subject, safe arguments, duration, result, diagnostic link, and chronological position | test status or retry policy |

The minimum selected-test explanation is: outcome category, failure/error
message, attempt/repeat, source location when present, cleanup and
infrastructure outcome, relevant step, and the narrowest valid rerun command.

The structured trace is the append-only event journal. Raw output is a separate
line-oriented log view. A trace row may point to a raw-log anchor in a future
schema, but the current transport does not supply anchors.

`Debug` in this viewer means a runner-controlled rerun or pause option only when
the runtime exposes one. It does not provide VS Code breakpoints, variables,
watches, stacks, or source editing. `Open Source` delegates to an external
configured editor and remains unavailable until an editor-launch contract
exists.

### View-model contracts

- **Run:** id, state, terminal flag, generation, scope/selection, repeat count
  and current repeat, current test, counts/totals, queue and execution timing,
  cleanup/infrastructure fields, elapsed time, and reproduce command.
- **Explorer node:** stable id, kind, label, parent/children, expanded/selected,
  source identity, and runner-supplied aggregate status.
- **Test result:** stable test id, attempt/repeat index, status, duration,
  failure category/message/trace/location, behavior outcome, cleanup outcome,
  and infrastructure outcome.
- **Trace step:** sequence, elapsed time, event type, group/test association,
  command/diagnostic payload, duration, retry/wait detail when supplied, source
  location, evidence reference, and raw-log anchor.
- **Evidence:** stable name, kind (`screen-cells`, `view-tree`, or textual),
  availability (`available`, `not-retained`, `unsupported`, or `failed`),
  capture timing, attempt/test association, and retained payload/reference.

The results pane title remains `TEST RESULTS`. Its breadcrumb communicates
scope. The selected test and active attempt are separate title-bar fields.

## Confirmed runtime capability decisions

The decisions below describe the current repository, not aspirational UI:

- **Run configuration supported:** project-relative `--spec`, one
  `--test-glob`, filters, excluded filters, names, tags, excluded tags, seed,
  repeat count, project/module roots, result policy/path, and runner lease
  settings. The viewer should expose only user-facing selection, filter, seed,
  and repeat settings; service plumbing stays out of the UI.
- **Repeat count supported:** yes, as a positive integer.
- **Attempt outcomes supported:** yes, by grouping `test.started`,
  `test.finished`, and problem events inside `repeat.started` /
  `repeat.finished`. “Attempt” is the UI name for a test occurrence in one
  repeat; it is derived, not a separate transport object.
- **Flake detection supported:** derivable within one repeated run when the
  same stable test identity has differing terminal statuses. The controller,
  not the table, computes it.
- **Structured commands supported:** yes for observed DwarfSpec subject/custom
  commands through `command.started` and `command.finished`. Safe arguments are
  currently an empty table, so the UI must not claim argument detail.
- **Source locations supported:** problem records may supply project-relative
  source, positive line, and optional column. Test-start only supplies a source
  identity. Command events do not currently supply locations.
- **Raw-log anchors supported:** no. Keep the affordance unavailable.
- **Retry/wait/poll details supported:** no structured event contract. Do not
  display invented retry timelines.
- **Host evidence supported internally:** named screen-cell and view-tree
  captures exist during a run, plus structured focus diagnostics. Named
  captures are not currently exposed in the public transport snapshot, so the
  viewer marks them `not-retained`/unavailable.
- **Evidence semantics:** event diagnostics are retained structured data;
  named captures are live-at-capture but not externally retained; no replay or
  live host-screen stream is promised.
- **External editor targeting:** no launcher contract in the current runner.
  Source/line/column can be displayed and copied, but `Open Source` is
  unavailable.
- **Debug-break and pause:** no runner debug-break or execution-pause contract.
  The UI does not present these as working actions.
- **Host events versus raw output:** structured event-journal entries are
  reliably separable from line-oriented run logs. Arbitrary DFHack stdout is
  not classified into a distinct host-event stream.
- **Cleanup:** `cleanup_confirmed` and `mount_cleanup_verified` are explicit.
  Successful cleanup is silent in the workspace; a visible cleanup indicator
  appears only for cleanup failure or incomplete verification.

## Reuse decisions for the runner

- Window owns the top-level frame; Panel owns framed/grouped regions; Divider
  owns separators; normal Scrollbar owns every scroll treatment.
- ResizingPanel is used only for genuinely content-sized groups. Pages owns
  mutually exclusive child views and is paired with TabBar when tabs control
  that selection.
- Tree View With Columns remains the explorer because hierarchical status
  columns are not a `widgets.List` semantic.
- Generic Table View remains the result index because arbitrary sortable
  columns are not a `widgets.List` semantic.
- Breadcrumb remains in the `TEST RESULTS` title bar.
- TextButton owns ordinary actions. ConfigureButton and HelpButton are
  reserved for their compact official semantics. HotkeyLabel is used only for
  a genuine clickable hotkey label. RadioButton is unavailable until a
  locally installed DFHack version supplies its implementation.
- CycleHotkeyLabel is preferred for a small finite choice; Dropdown is retained
  only when seeing the complete choice set is materially more usable.
  ToggleHotkeyLabel owns labeled textual On/Off choices. ButtonGroup is used
  only when graphical choices must stay synchronized with CycleHotkeyLabel.
- EditField is single-line; TextArea is genuinely multiline; WrappedLabel and
  TooltipLabel are read-only.
- `widgets.List` is used for chronological or flat selectable rows;
  FilteredList is used when that list also needs a text filter.
- Command Menu is reserved for transient action menus. `issue` is used for a
  concise failure or unavailable-state message. `targeting_prompt` is reserved
  for an active targeting or armed-debug prompt, which the current runner does
  not expose.
- Slider, RangeSlider, and DimensionsTooltip are library-completeness
  components and are not used by the current runner proposal.
- Any later generic or DwarfSpec component must record why an existing official
  widget, existing custom component, or a new variant cannot represent it.

The rules above are separation-of-concerns decisions, not permission to place
working runtime affordances in a static mockup. The runtime capability section
still wins: no editor launcher, execution pause, debug break, raw-log anchor,
retained capture, or successful-cleanup badge is presented as available.

## Penpot verification

The foundation Penpot audit was completed against the live `New File 1` design:

- The coverage matrix contains all 28 documented `gui.widgets` classes.
- Nineteen source-verifiable visual widgets have dedicated component pages.
  `RadioButton` has a dedicated source-blocked coverage page and no fabricated
  library component.
- Every widget page and the coverage page has one appropriately named
  top-level board and a pure-black `#000000` Canvas Background.
- All text on those pages uses `font.baseGame`, VT323, and the single 12 px
  game-text size.
- All solid colors and strokes are linked to the supplied DF palette. Official
  Premium raster-sheet pixels are preserved as source artwork. No numeric
  stand-in text remains for CP437 glyphs.
- The dedicated Command Menu master and its runner instance use
  `font.baseGame` at 12 px and palette-linked fills and strokes; the runner
  does not carry detached styling overrides for that composition.
- ConfigureButton and HelpButton use the shipped Premium control-panel tiles.
  Panel, Divider, and DimensionsTooltip use the appropriate Premium DFHack
  border sheets. Tab and TabBar use the installed Premium game tab sheet.
  Each visible Tab state is one composed 56-by-24 texture, with no per-cell Tab
  elements in Tab, TabBar, or the Pages composition.
  Slider and RangeSlider are documented Premium visual overrides. Their handles
  reuse diamond states from the shipped `scrollbar.png`, while their tracks,
  selected intervals, stops, and surfaces use linked DF palette colors.
- Slider has reusable `Stops`, `Index`, and `State` variants for five-stop rest,
  five-stop dragging, and two-stop rest examples. RangeSlider has reusable
  `Stops` and `State` variants for
  five-stop rest, five-stop whole-range dragging, and three-stop rest examples.
  Premium Slider uses one palette-built track plus one clipped official texture
  handle; Premium RangeSlider uses the same structure with two handles. Neither
  component exposes per-cell artwork.
- ButtonGroup supplies three tight 184-by-38 selection-state components. Each
  keeps its CycleHotkeyLabel on the first row and its caller-supplied graphical
  choices two cells below.
- The Premium Texture Assets page provides 23 complete texture-row components
  across the border, tab, control-panel, and scrollbar sheets. Low-level tile
  crops are hidden and retained only for existing composed frame masters.
- Printable ASCII that is emitted literally by DFHack remains base-game-font
  text because the supplied Penpot atlas catalog intentionally omits printable
  ASCII cells.

The current runner proposal was also audited:

- Tree View With Columns has no `TEST`, `RESULT`, or `R` header and no
  side-list of duplicate indicators.
- Each of its ten rows owns exactly one status asset inside the shared scroll
  viewport. Pass uses CP437 251, failure uses CP437 15, and error uses CP437 9;
  palette-linked indicator strokes preserve the status color.
- Connection and host-responsive state use CP437 251, follow-output and flow
  direction, breadcrumb separators, and the command prompt use CP437 16, and
  the visible behavior failure uses CP437 15.
- Unicode bullets, marks, arrows, multiplication signs, and decorative
  separators were removed. Textual punctuation remains printable CP437 through
  `font.baseGame`.
- Hidden list-based result layers and their one-off status rectangles were
  removed after confirming that Generic Table View is the live result index.
- The live Tree View With Columns, Generic Table View, Dropdown Control, basic
  Tree View, and Command Menu masters and specimens live on their dedicated
  component pages. The runner and component examples were rebound to those
  masters.
- Superseded Foundations masters and old linked examples remain only as
  hidden, clearly named recovery archives. No visible mockup or component
  specimen depends on them.
- The decorative workflow title, unsupported break/pause controls, and the
  duplicate bottom rerun command were removed. `Open Source` remains
  non-visible because no launcher contract exists. No protocol or DFHack
  version badge remains.
- Successful cleanup has no visible indicator. Cleanup appears only when it
  fails or cannot be verified.
- The mockup contains one command preview, one linked Breadcrumb in the
  `TEST RESULTS` title bar, one linked Generic Table View, and one linked Tree
  View With Columns.
