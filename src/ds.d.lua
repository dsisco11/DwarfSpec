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

---@alias dwarfspec.MouseInput
---| 'left_click'
---| 'left_down'
---| 'left_up'
---| 'right_click'
---| 'right_down'
---| 'right_up'
---| 'middle_click'
---| 'middle_down'
---| 'middle_up'
---| 'scroll_up'
---| 'scroll_down'

---@class dwarfspec.MouseInputEnum
---@field LEFT_CLICK `left_click`
---@field LEFT_DOWN `left_down`
---@field LEFT_UP `left_up`
---@field RIGHT_CLICK `right_click`
---@field RIGHT_DOWN `right_down`
---@field RIGHT_UP `right_up`
---@field MIDDLE_CLICK `middle_click`
---@field MIDDLE_DOWN `middle_down`
---@field MIDDLE_UP `middle_up`
---@field SCROLL_UP `scroll_up`
---@field SCROLL_DOWN `scroll_down`

---@class dwarfspec.WaitOptions
---@field timeout_ms? integer
---@field frame_budget? integer
---@field description? string

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

---Returns a stable diagnostic snapshot of this subject.
---@return dwarfspec.SubjectInspectState
function Subject:inspect() end

---Returns the stable inspected text value for this subject.
---@return string|nil
function Subject:text() end

---Returns the native DFHack object represented by this subject.
---@return table
function Subject:raw() end

---@class dwarfspec.DS
---@field protocol_version integer
---@field MouseInput dwarfspec.MouseInputEnum
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

---Mounts one supported component as the run's implicit current mount.
---@param component any
---@param options? dwarfspec.MountOptions
---@return dwarfspec.Subject
function DS.mount(component, options) end

---Returns a subject for the current component root.
---@return dwarfspec.Subject
function DS.root() end

---Unmounts and settles the current component.
function DS.unmount() end

---Selects one strict control path from the implicit current mount.
---@param control_path string
---@return dwarfspec.Subject
function DS.get(control_path) end

---Returns a stable read-only diagnostic table for one live view or subject.
---@param view? table|dwarfspec.Subject
---@return dwarfspec.SubjectInspectState
function DS.inspect(view) end

---Captures the current implicit mount tree under one evidence name.
---@param name string
---@return table
function DS.capture_view_tree(name) end

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
---@param input dwarfspec.MouseInput
---@return integer
function DS.mouseInput(input) end

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
