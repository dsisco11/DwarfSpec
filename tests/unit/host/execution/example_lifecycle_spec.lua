local module = require('dwarfspec.host.execution.example_lifecycle')

describe('host example lifecycle', function()
    it('resets in order and publishes detached example diagnostics', function()
        local resets, published = {}, {}
        local captures = 0
        local run = {output_lines={}, event_publisher={publish=function(kind, value)
            table.insert(published, {kind=kind, value=value})
        end}}
        local identity = {suite_id='suite:1', suite_name='suite',
            repeat_index=1, source_identity='suite.lua'}
        ---Copies the suite identity for detached lifecycle attribution.
        ---@return table
        function identity:copy()
            return {suite_id=self.suite_id, suite_name=self.suite_name,
                repeat_index=self.repeat_index,
                source_identity=self.source_identity, copy=self.copy}
        end
        local guard = {
            capture=function()
                captures = captures + 1
                return captures
            end,
            compare=function(_, before, after)
                return {kind='changed', content={before=before, after=after}}
            end,
        }
        local lifecycle = module.new(run, function(reason)
            table.insert(resets, reason)
        end, guard, {
            copy_json=function(value) return value end,
            event_type='diagnostic', change_kind='changed',
            format_warning=function() return 'warning' end,
        })
        lifecycle.suite_entry(identity)
        lifecycle.example_entry()
        lifecycle.test_start({example_name='works',
            source_identity='suite.lua:10'})
        lifecycle.example_exit()

        assert.same({'before example', 'after example'}, resets)
        assert.equals('diagnostic', published[1].kind)
        assert.equals('example', published[1].value.content.scope)
        assert.equals('works', published[1].value.content.example_name)
        assert.same({'warning'}, run.output_lines)
    end)

    it('installs entry and exit through the lifecycle adapter', function()
        local entry, exit
        local adapter = {
            install_example_entry=function(_, callback) entry = callback end,
            install_example_exit=function(_, callback) exit = callback end,
        }
        local lifecycle = {example_entry=function() end,
            example_exit=function() end}
        module.install_entry(adapter, {}, lifecycle)
        module.install_exit(adapter, {}, lifecycle)
        assert.equals(lifecycle.example_entry, entry)
        assert.equals(lifecycle.example_exit, exit)
    end)

    it('publishes suite comparisons and clears abandoned observations',
            function()
        local published = {}
        local identity={suite_id='suite', suite_name='name', repeat_index=2}
        ---Copies the suite identity for detached lifecycle attribution.
        ---@return table
        function identity:copy()
            return {suite_id=self.suite_id, suite_name=self.suite_name,
                repeat_index=self.repeat_index, copy=self.copy}
        end
        local lifecycle = module.new(
            {event_publisher={publish=function(_, value)
                table.insert(published, value)
            end}}, function() end, {
                capture=function() return {} end,
                compare=function()
                    return {kind='stable', content={}}
                end,
            }, {
                copy_json=function(value) return value end,
                event_type='diagnostic', change_kind='changed',
                format_warning=function() return 'warning' end,
            })
        lifecycle.suite_entry(identity)
        lifecycle.suite_exit(identity, 'suite')
        assert.equals('suite', published[1].content.scope)
        assert.equals('file', published[1].content.attribution)
        lifecycle.suite_entry(identity)
        lifecycle.clear()
        lifecycle.suite_exit(identity, 'suite')
        assert.equals(1, #published)
    end)

    it('propagates reset failures before capturing example state', function()
        local lifecycle = module.new(
            {event_publisher={publish=function() end}}, function(reason)
                if reason == 'before example' then error('reset failed') end
            end, {capture=function() return {} end,
                compare=function() return nil end}, {
                copy_json=function(value) return value end,
                event_type='diagnostic', change_kind='changed',
                format_warning=function() return 'warning' end,
            })
        local identity={suite_id='suite', suite_name='name', repeat_index=1}
        ---Copies the suite identity for detached lifecycle attribution.
        ---@return table
        function identity:copy()
            return {suite_id=self.suite_id, suite_name=self.suite_name,
                repeat_index=self.repeat_index, copy=self.copy}
        end
        lifecycle.suite_entry(identity)
        assert.has_error(lifecycle.example_entry, 'reset failed')
    end)
end)
