-- Behavioral signposts for mutations no Lua capability object can prevent.

local Context = require('dwarfspec.driver.command.context')

---Creates minimal read-context dependencies.
---@return table
local function dependencies()
    return {
        now_ms=function() return 0 end,
        remaining_ms=function() return 10 end,
        cancellation=function() return false end,
        resolve_mount=function() end,
        resolve_target=function() end,
        lookup_claim=function() end,
        capture_render=function() return 0 end,
        observe_render=function() return true end,
        record_diagnostic=function() end,
    }
end

---Creates one valid read context for conformance callbacks.
---@return dwarfspec.CommandReadContext
local function context()
    return Context.new_read({
        stage='preflight',
        identity={
            invocation_id='invocation-1',
            root_invocation_id='invocation-1',
            owner_scope='suite_execution',
            service_run_id='run-1',
            suite_execution_id='suite-1',
            cleanup_checkpoint=0,
        },
        dependencies=dependencies(),
    })
end

describe('read-only callback behavioral conformance signposts', function()
    it('detects direct native-object mutation outside context capabilities',
            function()
        local native = {value=1}
        local callback = function(read_context)
            assert.is_nil(read_context.mutate_native)
            native.value = 2
        end
        local before = native.value
        callback(context())
        assert.is_true(native.value ~= before)
    end)

    it('detects external global-like mutation outside context capabilities',
            function()
        local external_state = {count=0}
        local callback = function(read_context)
            assert.is_nil(read_context.publish_result)
            external_state.count = external_state.count + 1
        end
        local before = external_state.count
        callback(context())
        assert.is_true(external_state.count ~= before)
    end)
end)
