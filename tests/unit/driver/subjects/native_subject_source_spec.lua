local source = require('dwarfspec.driver.subjects.native_subject_source')

describe('native subject source', function()
    it('delegates source selection and dual-root resolution explicitly', function()
        local service = source.new({sources={NATIVE='native', OVERLAY='overlay'},
            is_native_widget_root=function() return true end,
            native_factory=function(root) return {kind='native', adapter={root=function() return root end}} end,
            overlay_factory=function(name) return {kind='overlay', overlay=name} end,
            mount_context={register_subject_source=function(_, value) return value end},
            resolve_implicit_path=function(_, path) return path end})
        local mount = {subject_source={kind='native'}, subject_sources={}, interaction_target={}}
        assert.equals('native', service.select(mount, {source='native'}).kind)
        assert.same({'info', 'creatures'}, service.resolve_implicit_path({}, {'info', 'creatures'}))
    end)
end)
