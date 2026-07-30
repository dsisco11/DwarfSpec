# DFHack widget rendering reference

This is the rendering authority for the Penpot widget specimens. It was
derived from the locally installed DFHack 53.15-r1 Lua source:

- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets.lua`
- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui\widgets\`
- `D:\CODE\DFHack\dfhack-53.15-r1\library\lua\gui.lua`

The online stable documentation currently describes DFHack 53.15-r2 and lists
28 public `gui.widgets` classes. The local 53.15-r1 aggregator exports 27.
`RadioButton` is the sole documented class absent from the installed source.
Its Penpot page is a source-blocked record, not a fabricated component.

The Penpot specimens use the existing CP437 atlas assets for every
non-printable or extended visual symbol, `font.baseGame` for text, and the
existing linked DF palette. The supplied atlas-asset catalog intentionally
omits printable ASCII cells. When the installed implementation renders a
printable literal such as `[`, `]`, `<`, `>`, `?`, or `_`, the specimen renders
that same literal with `font.baseGame`; it does not substitute a Unicode glyph
or a newly drawn icon. Where the local implementation selects a graphics
texture that is not present in Penpot, the specimen uses the implementation's
CP437 fallback.

## Installed-source rendering contracts

| Widget | Local rendering contract |
| --- | --- |
| `Widget` | Non-visual base. Computes frame/body geometry and only fills a background when `frame_background` is supplied. |
| `Panel` | Optional `gui.paint_frame` border, title, background, DFHack signature, drag/resize behavior, and vertical child auto-arrangement. |
| `Window` | `Panel` with `FRAME_WINDOW`, clear background, inset 1, and dragging enabled. |
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
| `ButtonGroup` | `CycleHotkeyLabel` plus synchronized graphical labels beginning two rows below. |
| `ToggleHotkeyLabel` | `CycleHotkeyLabel` specialized to green `On` and default-pen `Off`. |
| `ConfigureButton` | Fixed 3x1 cyan-bracket button with CP437 15 gear fallback in the center. |
| `HelpButton` | Fixed 3x1 cyan-bracket button with `?` fallback in the center. |
| `RadioButton` | **Not installed.** No local class, module, or rendering contract exists in DFHack 53.15-r1. |
| `BannerPanel` | Red `[` and `]` at the left and right of every row. |
| `TextButton` | `BannerPanel` containing a `HotkeyLabel` inset one cell on each side. |
| `List` | Cyan rows, light-cyan selected row, optional icon/right-aligned green hotkey, and the normal Scrollbar. |
| `FilteredList` | `EditField`, two-row gap, and `List`; optional reversed layout; light-red `No matches`. |
| `Tab` | Two rows, width `label + 4`; active text mode is yellow/white and inactive is brown/dark grey. |
| `TabBar` | `ResizingPanel` of Tabs; wraps or horizontally scrolls with CP437 17/16 left/right labels. |
| `RangeSlider` | CP437 198/205/216/181 track, grey unselected range, light-green selected range, and two black-on-yellow `<`, CP437 9, `>` handles. |
| `Slider` | The RangeSlider core with one centered black-on-yellow three-cell handle. |
| `DimensionsTooltip` | Auto-width `ResizingPanel`, `FRAME_THIN`, clear background, `XxYxZ`, cursor offset +3,+3, and screen clamping. |

## Frame rules

`Panel:onRenderFrame()` delegates to `gui.paint_frame()`, which paints corners,
edges, optional title, pause/resize badges, and—unless suppressed by the
frame style—the `DFHack` signature at lower right.

- `FRAME_WINDOW` and `FRAME_BOLD` use the double-line CP437 fallback.
- `FRAME_PANEL`, `FRAME_MEDIUM`, and `FRAME_THIN` use the single-line fallback.
- `FRAME_INTERIOR` and `FRAME_INTERIOR_MEDIUM` suppress the DFHack signature.
- Shared fallback junctions use CP437 194, 193, 195, 180, and 197.
