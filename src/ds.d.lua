---@meta

---@alias dwarfspec.EPointerAnchor
---| 'center'
---| 'top_left'
---| 'top_right'
---| 'bottom_left'
---| 'bottom_right'

---@alias dwarfspec.PointerAnchor dwarfspec.EPointerAnchor

---@alias dwarfspec.MouseButton
---| 'left'
---| 'right'
---| 'middle'

---@alias dwarfspec.EMouseButton
---| 'left'
---| 'right'
---| 'middle'
---| 'scroll_up'
---| 'scroll_down'

---@alias dwarfspec.EInputState
---| 'click'
---| 'down'
---| 'up'

---A supported DFHack state-change event identifier.
---@alias dwarfspec.EEvent
---| 'world_loaded'
---| 'world_unloaded'
---| 'map_loaded'
---| 'map_unloaded'
---| 'viewscreen_changed'
---| 'paused'
---| 'unpaused'

---The `ds.EPointerSpace.GRID` coordinate-space value.
---@alias dwarfspec.GridPointerSpace 1

---The `ds.EPointerSpace.PIXELS` coordinate-space value.
---@alias dwarfspec.PixelPointerSpace 2

---The `ds.EPointerSpace.WORLD_TILE` coordinate-space value.
---@alias dwarfspec.WorldTilePointerSpace 3

---A pointer coordinate space obtained from `ds.EPointerSpace`.
---@alias dwarfspec.EPointerSpace dwarfspec.GridPointerSpace|dwarfspec.PixelPointerSpace|dwarfspec.WorldTilePointerSpace

---@alias dwarfspec.EScreenOrigin
---| 'top_left'
---| 'top'
---| 'top_right'
---| 'left'
---| 'center'
---| 'right'
---| 'bottom_left'
---| 'bottom'
---| 'bottom_right'

---@alias dwarfspec.ESubjectSource
---| 'native'
---| 'overlay'

---A declared game-UI field, exact widget name, or zero-based widget index.
---@alias dwarfspec.NativePathSegment string|integer
---A nonempty native path. Declared fields may precede exact widget segments.
---@alias dwarfspec.NativePath dwarfspec.NativePathSegment[]

---@class dwarfspec.EMouseButtonEnum
---@field LEFT `left`
---@field RIGHT `right`
---@field MIDDLE `middle`
---@field SCROLL_UP `scroll_up`
---@field SCROLL_DOWN `scroll_down`

---@class dwarfspec.EInputStateEnum
---@field CLICK `click`
---@field DOWN `down`
---@field UP `up`

---Immutable identifiers for state-change events supported by `awaitEvent()`.
---@class dwarfspec.EEventEnum
---@field WORLD_LOADED `world_loaded`
---@field WORLD_UNLOADED `world_unloaded`
---@field MAP_LOADED `map_loaded`
---@field MAP_UNLOADED `map_unloaded`
---@field VIEWSCREEN_CHANGED `viewscreen_changed`
---@field PAUSED `paused`
---@field UNPAUSED `unpaused`

---Immutable pointer coordinate spaces. Use these members instead of backing
---values: `GRID` addresses UI-grid cells, `PIXELS` addresses screen pixels,
---and `WORLD_TILE` addresses map tiles.
---@class dwarfspec.EPointerSpaceEnum
---@field GRID dwarfspec.GridPointerSpace Zero-based UI-grid cells; the default.
---@field PIXELS dwarfspec.PixelPointerSpace Exact zero-based screen pixels.
---@field WORLD_TILE dwarfspec.WorldTilePointerSpace Zero-based world-map tiles.

---Immutable anchors for pointer placement within subject bounds.
---@class dwarfspec.EPointerAnchorEnum
---@field CENTER `center`
---@field TOP_LEFT `top_left`
---@field TOP_RIGHT `top_right`
---@field BOTTOM_LEFT `bottom_left`
---@field BOTTOM_RIGHT `bottom_right`

---Immutable map viewport anchors used by `getViewPos()` and `setViewPos()`.
---@class dwarfspec.EScreenOriginEnum
---@field TOP_LEFT `top_left`
---@field TOP `top`
---@field TOP_RIGHT `top_right`
---@field LEFT `left`
---@field CENTER `center`
---@field RIGHT `right`
---@field BOTTOM_LEFT `bottom_left`
---@field BOTTOM `bottom`
---@field BOTTOM_RIGHT `bottom_right`

---Immutable identifiers for inspectable native and registered-overlay sources.
---@class dwarfspec.ESubjectSourceEnum
---@field NATIVE `native`
---@field OVERLAY `overlay`

---Selects the borrowed native hierarchy, which is the default source.
---@class dwarfspec.NativeSubjectSourceOptions
---@field source? `native`
---@field overlay? nil
---@field native_root? userdata Advanced exact-root bypass for ambiguity or unsupported DF structures.

---Selects one externally owned widget from DFHack's live overlay registry.
---@class dwarfspec.OverlaySubjectSourceOptions
---@field source `overlay`
---@field overlay string Exact enabled overlay registry name.
---@field native_root? nil

---@alias dwarfspec.SubjectSourceOptions dwarfspec.NativeSubjectSourceOptions|dwarfspec.OverlaySubjectSourceOptions
---@alias dwarfspec.RootSourceOptions dwarfspec.SubjectSourceOptions
---@alias dwarfspec.GetSourceOptions dwarfspec.SubjectSourceOptions
---@alias dwarfspec.CaptureViewTreeSourceOptions dwarfspec.SubjectSourceOptions

---@class dwarfspec.WaitOptions
---@field timeout_ms? integer
---@field frame_budget? integer
---@field description? string

---@class dwarfspec.TickWaitOptions
---@field timeout_ms? integer Maximum wall-clock time in milliseconds before the wait fails; defaults to settings.wait.timeout_ms or 10000.
---@field description? string Operation name included in timeout diagnostics; defaults to `wait_ticks(count)`.

---Options for awaiting the next supported DFHack state-change event.
---@class dwarfspec.EventWaitOptions
---@field trigger? fun() Invoked after the native listener is armed; a matching synchronous event is captured.
---@field description? string Nonempty operation name included in diagnostics.
---@field timeout_ms? integer|false Positive command-local timeout in milliseconds; `false` or omission disables it.

---Normalized immutable payload captured while native event data is valid.
---Unavailable fields are omitted.
---@class dwarfspec.EventPayload
---@field save_directory? string Loaded or previously loaded save-directory name for world and map events.
---@field focus? string Current native focus for a viewscreen change.
---@field native_screen_type? string Current native screen type for a viewscreen change.
---@field paused? boolean Current pause state for pause and unpause events.

---Immutable snapshot of one supported DFHack event occurrence.
---@class dwarfspec.EventOccurrence
---@field event dwarfspec.EEvent Public event identifier that matched the wait.
---@field source `state_change` Fixed native event source.
---@field payload dwarfspec.EventPayload Normalized payload without transient native pointers.

---@class dwarfspec.RedrawOptions
---@field wait? boolean Wait for the resulting completed render; defaults to true.

---@class dwarfspec.WorldTilePointerOptions
---@field recenter? boolean Recenter the map view on the tile before moving; defaults to true.

---@class dwarfspec.Viewport
---@field width integer
---@field height integer

---@class dwarfspec.MapViewPosition
---@field x integer Map-tile x coordinate at the selected screen origin.
---@field y integer Map-tile y coordinate at the selected screen origin.
---@field z integer Zero-based map z-level.

---@class dwarfspec.OverlayPosition
---@field x integer
---@field y integer

---@class dwarfspec.MountOptions
---@field viewport? dwarfspec.Viewport
---@field backing_viewscreen? table
---@field overlay_position? dwarfspec.OverlayPosition
---@field fullscreen? boolean
---@field full_interface? boolean
---@field [string] any

---@class dwarfspec.ScreenCaptureOptions
---@field max_width? integer
---@field max_height? integer

---@class dwarfspec.SubjectInspectRect
---@field x1? integer
---@field y1? integer
---@field x2? integer
---@field y2? integer
---@field clip_x1? integer
---@field clip_y1? integer
---@field clip_x2? integer
---@field clip_y2? integer

---@class dwarfspec.SubjectInspectState
---@field class string
---@field view_id string|nil
---@field visible boolean
---@field active boolean
---@field focused boolean
---@field frame dwarfspec.SubjectInspectRect|nil
---@field body dwarfspec.SubjectInspectRect|nil
---@field text string|nil
---@field tooltip string|nil
---@field native_type? string Native DF widget type for native subjects.
---@field name? string Native widget name for native subjects.
---@field effective_visible? boolean Visibility including native ancestors.
---@field effective_active? boolean Activity including native ancestors.
---@field scroll_position? integer Native scroll-row position.
---@field visible_row_count? integer Native scroll-row visible count.
---@field selected_index? integer Native tabs, dropdown, or radio selection.

---@class dwarfspec.ScreenCell
---@field ch? integer
---@field fg? integer
---@field bg? integer
---@field bold? boolean
---@field tile? integer

---@class dwarfspec.ScreenCapture
---@field width integer
---@field height integer
---@field cells table<integer, table<integer, dwarfspec.ScreenCell|nil>>

---@class dwarfspec.Subject
local Subject = {}

---@class dwarfspec.MouseWheelOptions
---@field direction dwarfspec.EMouseButton
---@field steps? integer Defaults to one discrete wheel input.
---@field anchor? dwarfspec.EPointerAnchor

---Clicks this subject and preserves it for fluent chaining.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---It does not reverse game or UI effects caused by the click.
---@param button? dwarfspec.MouseButton
---@return dwarfspec.Subject
function Subject:click(button) end

---Moves the pointer over this subject in UI-grid cells and preserves it.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor? dwarfspec.EPointerAnchor
---@return dwarfspec.Subject
function Subject:hover(anchor) end

---Moves the pointer to this subject in UI-grid cells and preserves it.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor? dwarfspec.EPointerAnchor
---@return dwarfspec.Subject
function Subject:move_pointer(anchor) end

---Sends a discrete wheel-input batch over this subject and preserves it.
---Only the render after the complete batch is awaited.
---@param options dwarfspec.MouseWheelOptions
---@return dwarfspec.Subject
function Subject:mouseWheel(options) end

---Sends native input through this subject's mounted screen.
---@param keys string|string[]|table
---@return dwarfspec.Subject
function Subject:input(keys) end

---Types ASCII text through this subject's mounted screen.
---@param text string
---@return dwarfspec.Subject
function Subject:type(text) end

---Redraws this subject's mounted screen and waits by default.
---@param options? dwarfspec.RedrawOptions
---@return dwarfspec.Subject
function Subject:redraw(options) end

---Returns a stable diagnostic snapshot of this subject.
---@return dwarfspec.SubjectInspectState
function Subject:inspect() end

---Returns a copied focus-string list for this subject's current mounted screen.
---@return string[]
function Subject:getFocusList() end

---Returns the stable inspected text value for this subject.
---@return string|nil
function Subject:text() end

---Returns the exact Lua view table or typed native DF userdata for this subject.
---The returned object is borrowed and becomes invalid with its subject.
---@return table|userdata
function Subject:raw() end

---@class dwarfspec.DS
---@field protocol_version integer
---@field EEvent dwarfspec.EEventEnum
---@field EMouseButton dwarfspec.EMouseButtonEnum
---@field EInputState dwarfspec.EInputStateEnum
---@field EPointerSpace dwarfspec.EPointerSpaceEnum
---@field EPointerAnchor dwarfspec.EPointerAnchorEnum
---@field EScreenOrigin dwarfspec.EScreenOriginEnum
---@field ESubjectSource dwarfspec.ESubjectSourceEnum
local DS = {}

---Waits for actual DFHack raw-frame callbacks without blocking the game.
---@param count integer
---@param options? dwarfspec.WaitOptions
---@return integer
function DS.wait_frames(count, options) end

---Waits for unpaused Dwarf Fortress simulation ticks without blocking.
---@param count integer
---@param options? dwarfspec.TickWaitOptions
---@return integer
function DS.wait_ticks(count, options) end

---Polls a read-only condition once per frame until it becomes ready.
---@generic T
---@param description string
---@param query fun():T|nil|false
---@param options? dwarfspec.WaitOptions
---@return T
function DS.await(description, query, options) end

---Waits for the next matching event, even when its associated state is already
---true. The native listener is armed before an optional trigger runs, so an
---event raised synchronously by the trigger is captured. No command-local
---timeout is imposed unless `timeout_ms` is explicitly provided.
---@param event dwarfspec.EEvent
---@param options? dwarfspec.EventWaitOptions
---@return dwarfspec.EventOccurrence
function DS.awaitEvent(event, options) end

---Returns whether the Dwarf Fortress simulation is currently paused.
---@return boolean
function DS.isGamePaused() end

---Sets the game pause state for the current example.
---DwarfSpec automatically restores the inherited state during cleanup.
---@param paused boolean
---@return boolean
function DS.setGamePaused(paused) end

---Returns the current game ticks-per-second target.
---@return integer
function DS.getGameSpeed() end

---Sets the game ticks-per-second target for the current example.
---DwarfSpec automatically restores the inherited state during cleanup.
---@param tps integer
---@return integer
function DS.setGameSpeed(tps) end

---Returns the current in-year simulation tick for the loaded DF world.
---@return integer
function DS.getTick() end

---Returns DFHack's current millisecond clock value.
---@return integer
function DS.getTime() end

---Returns the directory name of the currently loaded save game.
---@return string
function DS.getSaveDirectoryName() end

---Ensures that one exact save directory is loaded.
---If another world is loaded, it is discarded without saving first. The
---requested world remains loaded for subsequent examples and is not restored
---or unloaded by example cleanup.
---@param directory_name string
---@return string
function DS.mountSaveGame(directory_name) end

---Returns whether the current DFHack focus matches one focus path.
---@param path string
---@return boolean
function DS.hasFocus(path) end

---Returns the map tile aligned with the selected screen origin.
---The origin defaults to `EScreenOrigin.CENTER`.
---@param origin? dwarfspec.EScreenOrigin
---@return dwarfspec.MapViewPosition
function DS.getViewPos(origin) end

---Aligns one map tile with the selected screen origin for the current example.
---The origin defaults to `EScreenOrigin.CENTER`.
---DwarfSpec automatically restores the inherited position during cleanup.
---@param position dwarfspec.MapViewPosition
---@param origin? dwarfspec.EScreenOrigin
---@return dwarfspec.MapViewPosition
function DS.setViewPos(position, origin) end

---Mounts one owned component or complete screen.
---DwarfSpec automatically unmounts it during example cleanup.
---@param component any
---@param options? dwarfspec.MountOptions
---@return dwarfspec.Subject
function DS.mount(component, options) end

---Mounts the current native DF screen without taking ownership of it.
---The mount creates, shows, resizes, and dismisses no screen.
---DwarfSpec automatically detaches the mount during example cleanup.
---@return dwarfspec.Subject
function DS.mountNativeScreen() end

---Returns a subject for the selected current-mount root.
---With no options, a native mount returns the exact borrowed
---`viewscreen.widgets` container. Source options are accepted only by a
---borrowed native-screen mount.
---@param options? dwarfspec.RootSourceOptions
---@return dwarfspec.Subject
function DS.root(options) end

---Releases the current native attachment or mounted component.
function DS.unmount() end

---Selects one exact path from the implicit current mount.
---On a borrowed native-screen mount without `native_root`, DwarfSpec checks
---both `viewscreen.widgets` and `df.global.game.main_interface`. Declared
---game-UI fields form a structural prefix; traversal switches permanently to
---exact widget names or zero-based indices at the first non-field segment on a
---widget container. Equal results are deduplicated and different results are
---reported as ambiguous. `native_root` bypasses this dual-root resolution.
---Component paths retain their strict direct-`subviews` behavior.
---@param control_path string|dwarfspec.NativePath
---@param options? dwarfspec.GetSourceOptions
---@return dwarfspec.Subject
function DS.get(control_path, options) end

---Returns a stable read-only diagnostic table for one live subject.
---@param view? dwarfspec.Subject Defaults to the current source root.
---@return dwarfspec.SubjectInspectState
function DS.inspect(view) end

---Invalidates the mounted screen and waits for a completed render by default.
---Pass `{wait=false}` to return after invalidation without waiting.
---@param view? dwarfspec.Subject Defaults to the current source root.
---@param options? dwarfspec.RedrawOptions
---@return any
function DS.redraw(view, options) end

---Captures the current implicit mount tree under one evidence name.
---Source options are accepted only by a borrowed native-screen mount.
---@param name string
---@param options? dwarfspec.CaptureViewTreeSourceOptions
---@return table
function DS.capture_view_tree(name, options) end

---Moves the pointer by subject anchor, UI-grid cell, exact screen pixel, or
---world tile.
---Numeric calls default to `EPointerSpace.GRID`. Explicit pixel calls preserve
---the requested pixel exactly and expose its derived UI-grid cell. World-tile
---calls recenter the map view by default; pass `{recenter=false}` to require
---the tile to already be visible. DwarfSpec reads current effective renderer
---geometry for each move and restores pointer and camera state automatically
---during cleanup.
---@overload fun(x: integer, y: integer): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.GridPointerSpace): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.PixelPointerSpace): integer, integer
---@overload fun(position: dwarfspec.MapViewPosition, space: dwarfspec.WorldTilePointerSpace, options?: dwarfspec.WorldTilePointerOptions): integer, integer, integer
---@param view? dwarfspec.Subject Defaults to the current source root.
---@param anchor? dwarfspec.EPointerAnchor Subject anchors use UI-grid cells.
---@return integer x
---@return integer y
function DS.move_pointer(view, anchor) end

---Moves the pointer over a subject or numeric coordinate and waits for render.
---Subject anchors use UI-grid cells. Numeric calls use the same coordinate
---space and return rules as `move_pointer`.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@overload fun(x: integer, y: integer): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.GridPointerSpace): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.PixelPointerSpace): integer, integer
---@param view? dwarfspec.Subject
---@param anchor? dwarfspec.EPointerAnchor
---@return integer x
---@return integer y
function DS.hover(view, anchor) end

---Sends supported native input and waits for the live screen to settle.
---@param keys string|string[]|table
---@param subject? dwarfspec.Subject
---@return integer
function DS.input(keys, subject) end

---Sends one mouse action at the current virtual pointer position.
---Physical mouse buttons default to the click input state.
---DwarfSpec automatically restores state owned by persistent `DOWN` or `UP`
---actions during cleanup.
---@param button dwarfspec.EMouseButton
---@param action? dwarfspec.EInputState
---@return integer
function DS.mouseInput(button, action) end

---Sends discrete wheel inputs at the current pointer or over a subject.
---Steps are inputs, not pixels or guaranteed scroll rows; only the final
---render is awaited.
---@param options dwarfspec.MouseWheelOptions
---@param subject? dwarfspec.Subject
---@return integer
function DS.mouseWheel(options, subject) end

---Clicks a view with a supported native mouse button and waits for render.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---It does not reverse game or UI effects caused by the click.
---@param view dwarfspec.Subject
---@param button? dwarfspec.MouseButton
---@return integer
function DS.click(view, button) end

---Types ASCII text through DFHack's supported string keycodes.
---@param text string
---@param subject? dwarfspec.Subject
---@return integer
function DS.type(text, subject) end

---Changes the current mounted component viewport and waits for its render.
---The viewport remains mount-scoped and ends with DwarfSpec's automatic
---unmount cleanup.
---@param width integer
---@param height integer
---@return any
function DS.viewport(width, height) end

---Captures and retains a bounded plain screen-cell buffer.
---@param name string
---@param options? dwarfspec.ScreenCaptureOptions
---@return dwarfspec.ScreenCapture
function DS.capture_screen(name, options) end

---Stages a real overlay source for a registration integration test.
---DwarfSpec automatically disables its overlays, restores configuration, and
---removes its unchanged staged script during lifecycle cleanup.
---@param source_path string
---@param logical_name string
---@return table
function DS.stage_overlay_registration(source_path, logical_name) end

---@diagnostic disable-next-line: lowercase-global
---@type dwarfspec.DS
ds = ds

return DS
