---@meta

---@alias dwarfspec.PointerAnchor
---| 'center'
---| 'top_left'
---| 'top_right'
---| 'bottom_left'
---| 'bottom_right'

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

---@alias dwarfspec.ESubjectSource
---| 'native'
---| 'overlay'

---@alias dwarfspec.NativePathSegment string|integer
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

---@class dwarfspec.ESubjectSourceEnum
---@field NATIVE `native`
---@field OVERLAY `overlay`

---@class dwarfspec.SubjectSourceOptions
---@field source? dwarfspec.ESubjectSource
---@field overlay? string Exact enabled overlay registry name required by the overlay source.

---@class dwarfspec.WaitOptions
---@field timeout_ms? integer
---@field frame_budget? integer
---@field description? string

---@class dwarfspec.RedrawOptions
---@field wait? boolean Wait for the resulting completed render; defaults to true.

---@class dwarfspec.Viewport
---@field width integer
---@field height integer

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

---Clicks this subject and preserves it for fluent chaining.
---@param button? dwarfspec.MouseButton
---@return dwarfspec.Subject
function Subject:click(button) end

---Moves the pointer over this subject and preserves it for fluent chaining.
---@param anchor? dwarfspec.PointerAnchor
---@return dwarfspec.Subject
function Subject:hover(anchor) end

---Moves the pointer to this subject and preserves it for fluent chaining.
---@param anchor? dwarfspec.PointerAnchor
---@return dwarfspec.Subject
function Subject:move_pointer(anchor) end

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

---Returns the stable inspected text value for this subject.
---@return string|nil
function Subject:text() end

---Returns the exact Lua view table or typed native DF object for this subject.
---@return table|userdata
function Subject:raw() end

---@class dwarfspec.DS
---@field protocol_version integer
---@field EMouseButton dwarfspec.EMouseButtonEnum
---@field EInputState dwarfspec.EInputStateEnum
---@field ESubjectSource dwarfspec.ESubjectSourceEnum
local DS = {}

---Waits for actual DFHack raw-frame callbacks without blocking the game.
---@param count integer
---@param options? dwarfspec.WaitOptions
---@return integer
function DS.wait_frames(count, options) end

---Polls a read-only condition once per frame until it becomes ready.
---@generic T
---@param description string
---@param query fun():T|nil|false
---@param options? dwarfspec.WaitOptions
---@return T
function DS.await(description, query, options) end

---Attaches to the native screen when omitted or mounts one component.
---@overload fun(): dwarfspec.Subject
---@param component any
---@param options? dwarfspec.MountOptions
---@return dwarfspec.Subject
function DS.mount(component, options) end

---Returns a subject for the selected current-mount root.
---@param options? dwarfspec.SubjectSourceOptions
---@return dwarfspec.Subject
function DS.root(options) end

---Unmounts and settles the current component.
function DS.unmount() end

---Selects one strict source-specific path from the implicit current mount.
---@param control_path string|dwarfspec.NativePath
---@param options? dwarfspec.SubjectSourceOptions
---@return dwarfspec.Subject
function DS.get(control_path, options) end

---Returns a stable read-only diagnostic table for one live view or subject.
---@param view? table|dwarfspec.Subject
---@return dwarfspec.SubjectInspectState
function DS.inspect(view) end

---Redraws a subject's mounted screen and waits by default.
---@param view table|dwarfspec.Subject
---@param options? dwarfspec.RedrawOptions
---@return any
function DS.redraw(view, options) end

---Captures the current implicit mount tree under one evidence name.
---@param name string
---@param options? dwarfspec.SubjectSourceOptions
---@return table
function DS.capture_view_tree(name, options) end

---Moves the virtual pointer to an anchor inside one live view body.
---@param view? table|dwarfspec.Subject
---@param anchor? dwarfspec.PointerAnchor
---@return integer x
---@return integer y
function DS.move_pointer(view, anchor) end

---Moves the virtual pointer over a subject and waits for its render.
---@param view? table|dwarfspec.Subject
---@param anchor? dwarfspec.PointerAnchor
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
---@param button dwarfspec.EMouseButton
---@param action? dwarfspec.EInputState
---@return integer
function DS.mouseInput(button, action) end

---Clicks a view with a supported native mouse button and waits for render.
---@param view table|dwarfspec.Subject
---@param button? dwarfspec.MouseButton
---@return integer
function DS.click(view, button) end

---Types ASCII text through DFHack's supported string keycodes.
---@param text string
---@param subject? dwarfspec.Subject
---@return integer
function DS.type(text, subject) end

---Changes the current mounted component viewport and waits for its render.
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
---@param source_path string
---@param logical_name string
---@return table
function DS.stage_overlay_registration(source_path, logical_name) end

---@diagnostic disable-next-line: lowercase-global
---@type dwarfspec.DS
ds = ds

return DS
