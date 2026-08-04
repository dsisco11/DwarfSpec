-- TestBed private construction cleanup contracts.

local internal = require('dwarfspec.testbed.internal')
local TestBed = require('dwarfspec.testbed')
local BaseEnvironment = require('dwarfspec.testbed.base_environment').BaseEnvironment
local PackageState = require('dwarfspec.testbed.package_state').PackageState

describe('TestBed internal construction', function()
    it('discards real allocated package state when later construction fails', function()
        local original_new = BaseEnvironment.new
        local original_close = PackageState.close
        local closed_state
        BaseEnvironment.new = function()
            error('injected base-environment construction failure')
        end
        PackageState.close = function(self)
            closed_state = self
            return original_close(self)
        end

        local ok, failure = xpcall(function()
            return internal.new(TestBed, {})
        end, debug.traceback)

        BaseEnvironment.new = original_new
        PackageState.close = original_close
        assert.is_false(ok)
        assert.matches('injected base-environment construction failure', failure,
            1, true)
        assert.is_not_nil(closed_state)
        assert.is_nil(closed_state.package)
        assert.is_nil(closed_state.base)
        assert.is_nil(closed_state.normalized)
    end)
end)
