# DFHack widget rendering reference

This is the rendering authority for the Penpot widget specimens. It was
derived from the locally installed DFHack 53.15-r1 Lua source:

- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets.lua`
- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets\`
- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui.lua`
- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\textures.lua`

The online stable documentation currently describes DFHack 53.15-r2 and lists
28 public `gui.widgets` classes. The local 53.15-r1 aggregator exports 27.
`RadioButton` is the sole documented class absent from the installed source.
Its Penpot page is a source-blocked record, not a fabricated component.

The Penpot specimens target Premium graphics mode. When a render pen supplies
both `tile` and `ch`, the Premium texture selected by `tile` is authoritative;
the CP437 character is only the legacy/text-mode fallback. The imported source
assets are the installed game `tabs.png`, `scrollbar.png`, and `border.png`
texture sheets plus DFHack's shipped `border-*.png` and `control-panel.png`
sheets. Penpot exposes reusable complete texture-row components for these
sheets. Individual tile crops are internal details used only by composed frame
masters; consumers do not model or render a frame as a public list of cells.
The installed PNGs are fully opaque. Their `#1C1C1C` pixels are source artwork,
not an alpha channel lost during import, and must not be removed with an
invented color key.
Penpot's `COLOR_BLACK` library color represents the Premium-rendered black pen
and therefore resolves to `#1C1C1C`. Widget, panel, window, and component
backgrounds link directly to that palette asset so their solid surfaces are
continuous with the Premium frame textures. Penpot page Canvas Background
properties are the deliberate exception and remain pure `#000000`.

Text and character-only pens still use `font.baseGame` at the one established
game-text size. Non-printable or extended character-only symbols use the
existing CP437 atlas assets. Printable literals such as `[`, `]`, `<`, `>`,
`?`, or `_` remain base-game-font text. Every surrounding solid text,
background, border, selection, and status color remains linked to the existing
DF palette. The pixels in the official imported raster sheets are source
artwork, not newly invented solid colors or substitutes.

## Installed-source rendering contracts

| Widget | Local rendering contract |
| --- | --- |
| `Widget` | Non-visual base. Computes frame/body geometry and only fills a background when `frame_background` is supplied. |
| `Panel` | Optional `gui.paint_frame` border using the selected DFHack Premium border sheet, title, background, DFHack signature, drag/resize behavior, and vertical child auto-arrangement. |
| `Window` | `Panel` with `FRAME_WINDOW` Premium border texture, clear background, inset 1, and dragging enabled. |
| `ResizingPanel` | `Panel` whose configured dimensions follow visible child extents plus frame and inset. |
| `Pages` | Container with exactly one visible child; selection chrome is external. |
| `Divider` | One-cell horizontal/vertical frame line with straight, junction, and crossing pens. |
| `EditField` | A `HotkeyLabel` followed by one-line `TextArea`; editable text defaults to light cyan. |
| `TextArea` | Multiline light-cyan input, cyan selection, blinking underscore cursor, wrapping, and the normal two-cell Scrollbar. |
| `Scrollbar` | Two cells wide; cyan caps/thumb, themed track, light-cyan hover; hidden when all elements fit. |
| `Label` | Tokenized normal, disabled, and hover pens; text, gaps, newlines, keys, tiles, and scrolling. |
| `WrappedLabel` | `Label` wrapping to body width minus three cells with configurable indentation and preserved explicit newlines. |
| `TooltipLabel` | Conditionally visible `WrappedLabel`; grey text and two-cell indent by default. |
| `HotkeyLabel` | Key, `": "` separator, label, and activation behavior. |
| `CycleHotkeyLabel` | Forward/optional reverse key, current option, optional label-below layout, and per-option pens. |
| `ButtonGroup` | `CycleHotkeyLabel` plus caller-supplied normal/selected graphical Labels beginning exactly two rows below. Every option has overlapping normal and selected Labels; visibility is synchronized to the current value. |
| `ToggleHotkeyLabel` | `CycleHotkeyLabel` specialized to green `On` and default-pen `Off`. |
| `ConfigureButton` | Fixed 3x1 button using Premium `control-panel.png` tiles 7, 10, and 8. Cyan brackets and CP437 15 are text-mode fallbacks. |
| `HelpButton` | Fixed 3x1 button using Premium `control-panel.png` tiles 7, 9, and 8. Cyan brackets and `?` are text-mode fallbacks. |
| `RadioButton` | **Not installed.** No local class, module, or rendering contract exists in DFHack 53.15-r1. |
| `BannerPanel` | Red `[` and `]` at the left and right of every row. |
| `TextButton` | `BannerPanel` containing a `HotkeyLabel` inset one cell on each side. |
| `List` | Cyan rows, light-cyan selected row, optional icon/right-aligned green hotkey, and the normal Scrollbar. |
| `FilteredList` | `EditField`, two-row gap, and `List`; optional reversed layout; light-red `No matches`. |
| `Tab` | Two rows, width `label + 4`; Premium mode composes each active or inactive tab into one complete texture instead of exposing one cropped element per cell. Text-mode yellow/white and brown/dark-grey artwork is fallback behavior. |
| `TabBar` | `ResizingPanel` of Premium Tabs; wraps or horizontally scrolls. Its character-only left/right scroll labels remain CP437 17/16 assets. |
| `RangeSlider` | The installed Lua renderer emits a one-row CP437 198/205/216/181 track with two black-on-yellow `<`, CP437 9, `>` handles. The Premium mockup is an intentional visual override: it reuses the shipped `scrollbar.png` diamond-handle states, uses linked DF palette colors for the track, selected interval, and stops, and contains no composed CP437 cells. Stop count and dual-handle interaction remain faithful to the source contract; the source frame-width formula is `width_per_idx * (num_stops - 1) + 7`, with `width_per_idx >= 5`. |
| `Slider` | The installed Lua renderer uses the one-row RangeSlider core with one black-on-yellow three-cell handle. The Premium mockup is an intentional visual override: it reuses the shipped `scrollbar.png` diamond-handle states and linked DF palette colors for the track, value interval, and stops, with no composed CP437 cells. Single-value selection and stop indexing remain faithful to the source contract; the source width formula uses `width_per_idx >= 3`. |
| `DimensionsTooltip` | Auto-width `ResizingPanel`, `FRAME_THIN`, clear background, `XxYxZ`, cursor offset +3,+3, and screen clamping. |

## Frame rules

`Panel:onRenderFrame()` delegates to `gui.paint_frame()`. In Premium graphics
mode, every corner, edge, junction, and frame decoration comes from the texture
sheet named by the frame style. The complete imported rows are the reusable
source primitives; the Panel, Divider, and DimensionsTooltip masters own the
necessary cropped edge composition.

- `FRAME_WINDOW`, `FRAME_PANEL`, `FRAME_MEDIUM`, `FRAME_THIN`, and
  `FRAME_BOLD` use their corresponding DFHack Premium border sheets.
- `FRAME_INTERIOR` and `FRAME_INTERIOR_MEDIUM` suppress the DFHack signature.
- CP437 corners, edges, and junctions are retained only as text-mode fallback
  contracts.
