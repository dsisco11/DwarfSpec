-- Root-only native subject adaptation used before widget traversal is enabled.

local ESubjectSource = require('dwarfspec.subject_sources')

local M = {}

---@class dwarfspec.NativeRootAdapter: dwarfspec.SubjectAdapter
---@field _root any|nil
---@field _interaction_target dwarfspec.BorrowedNativeInteractionTarget|nil
---@field _cleaned boolean
local NativeRootAdapter = {}
NativeRootAdapter.__index = NativeRootAdapter

---Validates mount currentness and returns the exact pinned widget container.
---@param self dwarfspec.NativeRootAdapter
---@param operation string
---@return any
local function require_root(self, operation)
    assert(not self._cleaned and self._root ~= nil and
        self._interaction_target,
        operation .. ' native subject source is no longer available')
    self._interaction_target:assert_current(operation)
    return self._root
end

---Returns the exact pinned native widget container.
---@return any
function NativeRootAdapter:root()
    return require_root(self, 'native root access')
end

---Resolves only the root until native widget traversal is installed.
---@param path_segments dwarfspec.NativePathSegment[]
---@return any|nil, table|nil
function NativeRootAdapter:resolve(path_segments)
    assert(type(path_segments) == 'table',
        'native subject resolution requires path segments')
    local root = require_root(self, 'native subject resolution')
    if #path_segments == 0 then return root end
    return nil, {
        index=1,
        segment=path_segments[1],
        parent=root,
    }
end

---Returns the stable typed-reference identity for the pinned root.
---@param raw any
---@return any
function NativeRootAdapter:identity(raw)
    require_root(self, 'native subject identity')
    return raw
end

---Returns whether a raw object is the exact pinned widget container.
---@param raw any
---@return boolean
function NativeRootAdapter:contains(raw)
    return raw == require_root(self, 'native subject containment')
end

---Returns no descendants until native traversal support is installed.
---@param raw any
---@return table
function NativeRootAdapter:children(raw)
    assert(self:contains(raw),
        'native root adapter cannot enumerate an unrelated object')
    return {}
end

---Returns the stable diagnostic name for the native widget root.
---@param raw any
---@return string
function NativeRootAdapter:name(raw)
    assert(self:contains(raw),
        'native root adapter cannot name an unrelated object')
    return '<native-root>'
end

---Returns the stable native type label for the widget container.
---@param raw any
---@return string
function NativeRootAdapter:native_type(raw)
    assert(self:contains(raw),
        'native root adapter cannot type an unrelated object')
    return 'df.widget_container'
end

---Returns no pointer bounds for the root-only adapter.
---@param raw any
---@return nil
function NativeRootAdapter:bounds(raw)
    assert(self:contains(raw),
        'native root adapter cannot read bounds from an unrelated object')
    return nil
end

---Returns the direct visibility of the native root container.
---@param raw any
---@return boolean
function NativeRootAdapter:visible(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return true
end

---Returns the direct activity of the native root container.
---@param raw any
---@return boolean
function NativeRootAdapter:active(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return true
end

---Returns whether the root container itself owns focus.
---@param raw any
---@return boolean
function NativeRootAdapter:focused(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return false
end

---Returns no text before type-aware native extraction is installed.
---@param raw any
---@return nil
function NativeRootAdapter:text(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return nil
end

---Returns no tooltip before type-aware native extraction is installed.
---@param raw any
---@return nil
function NativeRootAdapter:tooltip(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return nil
end

---Returns no optional fields for the root-only native adapter.
---@param raw any
---@return table
function NativeRootAdapter:optional_fields(raw)
    assert(self:contains(raw),
        'native root adapter cannot inspect an unrelated object')
    return {}
end

---Returns one bounded root-container inspection record.
---@param raw any
---@return table
function NativeRootAdapter:inspect(raw)
    return {
        class=self:native_type(raw),
        view_id=nil,
        visible=self:visible(raw),
        active=self:active(raw),
        focused=self:focused(raw),
        frame=nil,
        body=nil,
        text=nil,
        tooltip=nil,
    }
end

---Releases the borrowed root and interaction references.
---@return boolean
function NativeRootAdapter:cleanup()
    if self._cleaned then return false end
    self._cleaned = true
    self._root = nil
    self._interaction_target = nil
    return true
end

---Creates a root-only adapter for an exact native widget container.
---@param root any
---@param interaction_target dwarfspec.BorrowedNativeInteractionTarget
---@return dwarfspec.NativeRootAdapter
function M.new(root, interaction_target)
    assert(root ~= nil, 'native root adapter requires a widget container')
    assert(type(interaction_target) == 'table' and
        type(interaction_target.assert_current) == 'function',
        'native root adapter requires an interaction target')
    return setmetatable({
        _root=root,
        _interaction_target=interaction_target,
        _cleaned=false,
    }, NativeRootAdapter)
end

---Creates the default native subject source for one pinned attachment.
---@param root any
---@param interaction_target dwarfspec.BorrowedNativeInteractionTarget
---@return dwarfspec.SubjectSource
function M.new_source(root, interaction_target)
    return {
        kind=ESubjectSource.NATIVE,
        adapter=M.new(root, interaction_target),
    }
end

return M
