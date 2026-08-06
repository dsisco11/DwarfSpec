-- Unit contracts for finite command and cleanup timeout policy.

local settings = require('dwarfspec.protocol.configuration.settings')
local TimeoutPolicy = require(
    'dwarfspec.protocol.configuration.timeout_policy')

describe('verified execution timeout policy', function()
    it('validates finite settings while preserving frame budgets', function()
        local value = settings.validate({
            command={timeout_ms=20}, cleanup={timeout_ms=30},
            wait={timeout_ms=40, frame_budget=50},
        }, 'test')
        assert.equals(20, value.command.timeout_ms)
        assert.equals(30, value.cleanup.timeout_ms)
        assert.equals(50, value.wait.frame_budget)
        for _, invalid in ipairs({0, -1, 1.5, math.huge, false, '10'}) do
            assert.has_error(function()
                settings.validate({command={timeout_ms=invalid}}, 'test')
            end)
            assert.has_error(function()
                settings.validate({cleanup={timeout_ms=invalid}}, 'test')
            end)
        end
    end)

    it('applies command precedence and bounded legacy diagnostics', function()
        local policy = TimeoutPolicy.new()
        assert.same({10000, 'framework'}, (function()
            local result = policy:resolve_command(nil, nil, nil, nil)
            return {result.timeout_ms, result.source}
        end)())
        local definition = policy:resolve_command(nil, {}, 70)
        assert.equals('definition', definition.source)
        local project = policy:resolve_command(nil, {
            command={timeout_ms=60}, wait={timeout_ms=80},
        }, 70)
        assert.equals(60, project.timeout_ms)
        assert.equals('project', project.source)
        assert.equals(1, #project.diagnostics)
        local invocation = policy:resolve_command(50,
            {command={timeout_ms=60}}, 70)
        assert.equals('invocation', invocation.source)
        local legacy = policy:resolve_command(nil, {wait={timeout_ms=80}}, 70)
        assert.equals('legacy_wait', legacy.source)
        assert.equals(1, #legacy.diagnostics)
    end)

    it('bounds compatibility false by the enclosing run lease', function()
        local policy = TimeoutPolicy.new()
        local result = policy:resolve_command(false, nil, nil, 90, true)
        assert.equals(90, result.timeout_ms)
        assert.equals('run_lease', result.source)
        assert.is_true(result.legacy_unlimited)
        assert.has_error(function()
            policy:resolve_command(false, nil, nil, nil, true)
        end)
        assert.has_error(function()
            policy:resolve_command(false, nil, nil, 90, false)
        end)
    end)

    it('applies cleanup precedence without an unlimited value', function()
        local policy = TimeoutPolicy.new()
        assert.equals('framework', policy:resolve_cleanup(nil, {}).source)
        assert.equals('project', policy:resolve_cleanup(nil,
            {cleanup={timeout_ms=40}}).source)
        assert.equals('registration', policy:resolve_cleanup(30,
            {cleanup={timeout_ms=40}}).source)
        assert.has_error(function() policy:resolve_cleanup(false, {}) end)
    end)
end)
