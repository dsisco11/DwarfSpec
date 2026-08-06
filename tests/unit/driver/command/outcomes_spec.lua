-- Structural contracts for explicit command outcome constructors.

local Outcomes = require('dwarfspec.driver.command.outcomes')

---Asserts that a callback fails with diagnostic text.
---@param callback fun()
---@param text string
local function assert_error(callback, text)
    local succeeded, message = pcall(callback)
    assert.is_false(succeeded)
    assert.is_truthy(tostring(message):find(text, 1, true))
end

describe('command outcomes', function()
    it('constructs every explicit gate and verification outcome', function()
        assert.equals('ready', Outcomes.ready(nil, {observed=true}).kind)
        assert.equals('pending', Outcomes.pending('waiting').kind)
        assert.equals('fatal', Outcomes.fatal('invalid').kind)
        assert.equals('effect_absent',
            Outcomes.effect_absent('rolled back', {item_id='item-1'}).kind)
    end)

    it('keeps execution evidence and effect identity distinct', function()
        local executed = Outcomes.executed('public', {ack='accepted'},
            {item_id='item-1'})
        local retry = Outcomes.retry('try again', {attempt=1},
            {item_id='partial'}, {native='busy'})
        local failed = Outcomes.failed('partial failure',
            {item_id='partial'}, {stage='native'})
        assert.equals('public', executed.public_result)
        assert.equals('accepted', executed.receipt.ack)
        assert.equals('item-1', executed.effect_receipt.item_id)
        assert.equals(1, retry.attempt_receipt.attempt)
        assert.equals('partial', retry.effect_receipt.item_id)
        assert.equals('partial', failed.effect_receipt.item_id)
        assert.is_nil(failed.receipt)
    end)

    it('makes omitted effect receipts an explicit no-effect representation',
            function()
        assert.is_nil(Outcomes.executed(false, {ack=false}).effect_receipt)
        assert.is_nil(Outcomes.retry('safe retry', nil).effect_receipt)
        assert.is_nil(Outcomes.failed('failed before mutation').effect_receipt)
        assert.equals(false, Outcomes.executed(false).public_result)
        assert.is_nil(Outcomes.executed(nil).public_result)
    end)

    it('freezes private receipts and bounded diagnostic evidence', function()
        local outcome = Outcomes.executed(nil, {nested={value=1}},
            {item_id='item-1'})
        assert_error(function() outcome.kind = 'retry' end, 'immutable')
        assert_error(function() outcome.receipt.nested.value = 2 end,
            'immutable')
        assert_error(function()
            Outcomes.fatal('bad', {callback=function() end})
        end, 'plain data')
        assert_error(function() Outcomes.retry('', nil) end, 'nonempty')
        assert_error(function() Outcomes.effect_absent('gone') end,
            'observation evidence')
        assert_error(function() Outcomes.effect_absent('gone', {}) end,
            'observation evidence')
    end)
end)
