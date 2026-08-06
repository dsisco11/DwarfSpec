-- Bounded and serialization-safe command diagnostics contracts.

local Diagnostics = require('dwarfspec.driver.command.diagnostics')

describe('command diagnostics sanitization', function()
    it('detaches and freezes bounded plain evidence', function()
        local source = {id='target-1', nested={value=2}}
        local evidence = Diagnostics.new():sanitize(source)
        source.id = 'changed'
        source.nested.value = 9
        assert.equals('target-1', evidence.id)
        assert.equals(2, evidence.nested.value)
        assert.has_error(function() evidence.id = 'changed' end)
        assert.has_error(function() evidence.nested.value = 9 end)
    end)

    it('rejects callbacks, threads, cycles, and every configured bound',
            function()
        local diagnostics = Diagnostics.new({
            max_depth=2, max_entries=2, max_string_length=64,
        })
        assert.has_error(function()
            diagnostics:sanitize({callback=function() end})
        end)
        assert.has_error(function()
            diagnostics:sanitize({thread=coroutine.create(function() end)})
        end)
        local cycle = {}
        cycle.self = cycle
        assert.has_error(function() diagnostics:sanitize(cycle) end)
        assert.has_error(function()
            diagnostics:sanitize({nested={too={deep=true}}})
        end)
        assert.has_error(function()
            diagnostics:sanitize({one=1, two=2, three=3})
        end)
        assert.has_error(function()
            diagnostics:sanitize({message=string.rep('x', 65)})
        end)
        assert.has_error(function()
            diagnostics:record(string.rep('x', 65), {})
        end)
        assert.has_error(function()
            diagnostics:record_pending('stage', string.rep('x', 65))
        end)
        assert.has_error(function()
            Diagnostics.new({max_string_length=2})
        end)
    end)
end)

describe('command diagnostic retention', function()
    it('aggregates repeated pending observations with bounded samples',
            function()
        local diagnostics = Diagnostics.new({pending_sample_limit=2})
        diagnostics:record_pending('preflight', 'waiting', {attempt=1})
        diagnostics:record_pending('preflight', 'waiting', {attempt=2})
        local aggregate = diagnostics:record_pending(
            'preflight', 'waiting', {attempt=3})
        assert.equals(3, aggregate.count)
        assert.equals(2, #aggregate.samples)
        assert.equals(1, aggregate.samples[1].attempt)
        assert.equals(3, aggregate.samples[2].attempt)
        assert.equals(1, #diagnostics:snapshot().pending)
    end)

    it('bounds retained record counts and summarizes dropped data', function()
        local diagnostics = Diagnostics.new({max_records=2})
        diagnostics:record('one', {})
        diagnostics:record('two', {})
        diagnostics:record('three', {})
        diagnostics:record_pending('one', 'a')
        diagnostics:record_pending('two', 'b')
        local dropped = diagnostics:record_pending('three', 'c')
        local snapshot = diagnostics:snapshot()
        assert.equals(2, #snapshot.entries)
        assert.equals(1, snapshot.dropped_entries)
        assert.equals(2, #snapshot.pending)
        assert.equals(1, snapshot.dropped_pending)
        assert.is_false(dropped.retained)
    end)

    it('publishes only provider projections and records provider failures',
            function()
        local diagnostics = Diagnostics.new()
        local request = {callback=function() end, unrestricted='secret'}
        local projected, failure = diagnostics:project(function(value)
            return {label=value.unrestricted:sub(1, 1)}
        end, request, {native='mutable'})
        assert.equals('s', projected.label)
        assert.is_nil(failure)
        assert.is_nil(projected.callback)
        projected, failure = diagnostics:project(function()
            error('capture unavailable')
        end, request, nil)
        assert.is_nil(projected)
        assert.equals('diagnostic_provider_failed', failure.kind)
        projected, failure = diagnostics:project(function()
            error(setmetatable({}, {
                __tostring=function() error('unprintable') end,
            }))
        end, request, nil)
        assert.is_nil(projected)
        assert.equals('<unprintable diagnostic error>',
            failure.evidence.message)
        projected, failure = diagnostics:project(function()
            return {callback=function() end}
        end, request, nil)
        assert.is_nil(projected)
        assert.equals('diagnostic_provider_failed', failure.kind)
    end)

    it('retains originating failure when artifact capture also fails',
            function()
        local diagnostics = Diagnostics.new({max_string_length=64})
        local entry = diagnostics:record_artifact_failure(
            'screen', 'renderer unavailable',
            {stage='execution', message='original failure'})
        assert.equals('artifact_capture_failed', entry.kind)
        assert.equals('execution',
            entry.evidence.originating_failure.stage)
        assert.equals('original failure',
            entry.evidence.originating_failure.message)
        assert.equals('renderer unavailable', entry.evidence.message)
        local hostile = setmetatable({}, {
            __tostring=function() error('unprintable') end,
        })
        entry = diagnostics:record_artifact_failure(
            'tree', hostile, {stage='execution'})
        assert.equals('<unprintable diagnostic error>', entry.evidence.message)
    end)
end)
