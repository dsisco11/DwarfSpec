-- Native and overlay subject-source construction helpers.

local M = {}

---Creates the source-selection service for one mounted native screen.
---@param dependencies table
---@return table
function M.new(dependencies)
    assert(type(dependencies.resolve_implicit_path) == 'function',
        'DwarfSpec native subject source requires implicit path resolution')
    local function select(mount, request)
        assert(mount.subject_source.kind == dependencies.sources.NATIVE,
            'component mounts do not accept subject source options')
        if request.source == dependencies.sources.NATIVE then
            if request.native_root == nil then return mount.subject_source end
            local root_ok, is_root = pcall(dependencies.is_native_widget_root,
                request.native_root)
            assert(root_ok and is_root,
                'native_root must be a DF widget_container exposed by DFHack')
            for source in pairs(mount.subject_sources) do
                if source.kind == dependencies.sources.NATIVE and
                        source.adapter:root() == request.native_root then
                    return source
                end
            end
            local source = dependencies.native_factory(request.native_root,
                mount.interaction_target)
            assert(type(source) == 'table' and source.kind == dependencies.sources.NATIVE and
                source.adapter:root() == request.native_root,
                'native subject source factory returned an invalid source')
            return dependencies.mount_context:register_subject_source(source)
        end
        local source = dependencies.overlay_factory(request.overlay)
        assert(type(source) == 'table' and source.kind == dependencies.sources.OVERLAY and
            source.overlay == request.overlay,
            'overlay subject source factory returned an invalid source')
        return dependencies.mount_context:register_subject_source(source)
    end
    return {
        ---Selects a native or registered-overlay subject source.
        ---@param mount table
        ---@param request table
        ---@return table
        select=function(mount, request)
            return select(mount, request)
        end,
        ---Resolves an implicit native path against the supported roots.
        ---@param mount table
        ---@param path_segments table
        ---@param diagnostic_path string
        ---@return table
        resolve_implicit_path=function(mount, path_segments, diagnostic_path)
            return dependencies.resolve_implicit_path(mount, path_segments,
                diagnostic_path)
        end,
    }
end

return M
