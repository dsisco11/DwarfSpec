local observer_module = require('dwarfspec.driver.render.command_observer')

describe('command observer', function()
    it('publishes command boundaries and a bounded failure diagnostic', function()
        local events = {}
        local observer = observer_module.new({now_ms=function() return 7 end,
            publish=function(kind, payload) table.insert(events, {kind, payload}) end},
            {COMMAND_STARTED='started', COMMAND_FINISHED='finished', DIAGNOSTIC_RECORDED='diagnostic'},
            {SUCCESS='success', ERROR='error'})
        local observation = observer.started('command', {mount_id=2, control_path='root'})
        observer.finished(observation, false, 'broken')
        assert.equals('started', events[1][1])
        assert.equals('error', events[2][2].status)
        assert.equals('broken', events[3][2].content.message)
    end)
end)
