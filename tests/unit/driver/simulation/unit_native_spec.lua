local module = require('dwarfspec.driver.simulation.unit_native')

describe('driver native unit helpers', function()
    it('detects a ridden unit without reading a nonexistent riders field', function()
        local unit = {flags1={ridden=true}}
        assert.is_true(module.has_rider(unit, {
            get_general_ref=function()
                error('ridden flag should short-circuit general references')
            end,
            rider_ref_type=57,
        }))
    end)

    it('detects and rejects a native rider general reference', function()
        local reference = {}
        local unit = {flags1={ridden=false}}
        assert.is_true(module.has_rider(unit, {
            get_general_ref=function(candidate, reference_type)
                assert.equals(unit, candidate)
                assert.equals(57, reference_type)
                return reference
            end,
            rider_ref_type=57,
        }))
    end)

    it('accepts a unit with no rider signal', function()
        local unit = {flags1={ridden=false}}
        assert.is_false(module.has_rider(unit, {
            get_general_ref=function() return nil end,
            rider_ref_type=57,
        }))
    end)

    it('detects rider flag and mount relationship forms', function()
        assert.is_true(module.is_rider({
            flags1={rider=true}, relationship_ids={},
        }, {rider_mount_relationship=8}))
        assert.is_true(module.is_rider({
            flags1={rider=false}, relationship_ids={[8]=42},
        }, {rider_mount_relationship=8}))
        assert.is_false(module.is_rider({
            flags1={rider=false}, relationship_ids={[8]=-1},
        }, {rider_mount_relationship=8}))
    end)
end)
