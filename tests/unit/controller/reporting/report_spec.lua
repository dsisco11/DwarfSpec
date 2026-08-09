-- Controller rendering contracts for stage-aware command evidence.

local EventType = require('dwarfspec.protocol.enums.event_types')
local report = require('dwarfspec.controller.reporting.report')

describe('command event reporting', function()
    it('renders stage and terminal evidence without interpreting semantics',
            function()
        local lines = report.format_events({
            {type=EventType.COMMAND_STARTED,
                payload={name='synthetic'}},
            {type=EventType.COMMAND_STAGE,
                payload={name='synthetic', stage='preflight', status='pending',
                    attempt=1, duration_ms=2}},
            {type=EventType.COMMAND_FINISHED,
                payload={name='synthetic', status='failure', stage='preflight',
                    attempt_count=1, duration_ms=5}},
        })
        assert.same({'COMMAND synthetic started',
            'COMMAND synthetic preflight pending attempt=1 (2 ms)',
            'COMMAND synthetic failure stage=preflight attempts=1 (5 ms)'},
            lines)
    end)
end)
