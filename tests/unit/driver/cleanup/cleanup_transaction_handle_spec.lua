-- Unit contracts for caller-visible cleanup transaction handles.

local CleanupTransactionHandle = require(
    'dwarfspec.driver.cleanup.cleanup_transaction_handle')

---@param scope string
---@param attempt? string
---@return table
local function owner(scope, attempt)
    return {owner_scope=scope, service_run_id='run',
        suite_execution_id='suite', test_attempt_id=attempt}
end

describe('CleanupTransactionHandle', function()
    it('allows early execution only while the registering owner is active',
            function()
        local active = owner('test_attempt', 'attempt')
        local executions = 0
        local transaction = {
            execute=function(_, reason)
                executions = executions + 1
                assert.equals('manual', reason)
                return true
            end,
            isPending=function() return executions == 0 end,
            claimReferences=function() return {{claim_key='unit'}} end,
        }
        local handle = CleanupTransactionHandle.new(transaction, active,
            function() return active end, function() end)

        assert.is_true(handle:isPending())
        assert.equals('unit', handle:claimReferences()[1].claim_key)
        assert.is_true(handle:execute('manual'))
        assert.is_false(handle:isPending())

        active = owner('suite_execution')
        assert.has_error(function() handle:execute('manual') end,
            'cleanup handle execution is forbidden outside its owning lifecycle')
    end)

    it('lets suite-owned cleanup execute from a nested test owner', function()
        local active = owner('test_attempt', 'attempt')
        local handle = CleanupTransactionHandle.new({
            execute=function() return true end,
            isPending=function() return true end,
            claimReferences=function() return {} end,
        }, owner('suite_execution'), function() return active end,
            function() end)

        assert.is_true(handle:execute())
    end)

    it('returns already-expended state and propagates cleanup failures', function()
        local active = owner('test_attempt', 'attempt')
        local expended = CleanupTransactionHandle.new({
            execute=function() return false end,
            isPending=function() return false end,
            claimReferences=function() return {} end,
        }, active, function() return active end, function() end)
        assert.is_false(expended:execute())

        local failed = CleanupTransactionHandle.new({
            execute=function() error('restore failed') end,
            isPending=function() return true end,
            claimReferences=function() return {} end,
        }, active, function() return active end, function() end)
        assert.has_error(function() failed:execute() end, 'restore failed')
    end)

    it('applies the central stage guard before transaction mutation', function()
        local active = owner('test_attempt', 'attempt')
        local executed = false
        local handle = CleanupTransactionHandle.new({
            execute=function() executed = true end,
            isPending=function() return true end,
            claimReferences=function() return {} end,
        }, active, function() return active end, function()
            error('cleanup handle execution is forbidden during command execution')
        end)

        assert.has_error(function() handle:execute() end,
            'cleanup handle execution is forbidden during command execution')
        assert.is_false(executed)
    end)
end)
