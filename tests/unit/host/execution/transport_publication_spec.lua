local module = require('dwarfspec.host.execution.transport_publication')

describe('host transport publication', function()
    it('binds every event to the run generation', function()
        local observed
        local publisher = module.new_publisher(
            {run_id='run', generation=5}, {
                now_ms=function() return 10 end,
                publish_active_event=function(run_id, generation, kind,
                        payload)
                    observed = {run_id, generation, kind, payload}
                    return 7
                end,
            })
        assert.equals(10, publisher.now_ms())
        assert.equals(7, publisher.publish('started', {sequence=1}))
        assert.same({'run', 5, 'started', {sequence=1}}, observed)
    end)

    it('propagates generation rejection from the service boundary', function()
        local publisher = module.new_publisher(
            {run_id='run', generation=4}, {
                now_ms=function() return 10 end,
                publish_active_event=function(_, generation)
                    assert.equals(4, generation)
                    error('stale generation')
                end,
            })
        assert.has_error(function() publisher.publish('started', {}) end,
            'stale generation')
    end)

    it('publishes through the active run publisher', function()
        local observed
        module.publish({event_publisher={publish=function(kind, payload)
            observed = {kind=kind, payload=payload}
        end}}, 'finished', {generation=3})
        assert.same({kind='finished', payload={generation=3}}, observed)
    end)

    it('rejects runs without an event publisher', function()
        assert.has_error(function() module.publish({}, 'event', {}) end,
            'active run does not own an event publisher')
    end)

    it('encodes canonical transport values and propagates JSON failures',
            function()
        local options
        local encoder={encode=function(transport, received_options)
            options = received_options
            assert.same({run_id='run', after_sequence=2}, transport)
            return '{"run_id":"run","after_sequence":2}'
        end}
        local null={}
        local encoded = module.encode(
            {run_id='run', after_sequence=2}, null, encoder)
        assert.equals('{"run_id":"run","after_sequence":2}', encoded)
        assert.same({pretty=false, null=null}, options)
        assert.has_error(function()
            module.encode({}, nil, {encode=function()
                error('encoding failed')
            end})
        end, 'encoding failed')
    end)
end)
