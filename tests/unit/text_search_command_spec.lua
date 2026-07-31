-- Unit contracts for the rendered-text search command primitives.

local text_search = require('dwarfspec.commands.text_search')

---Asserts that one callback fails with an exact message.
---@param message string
---@param callback function
local function assert_error(message, callback)
    assert.has_error(callback, message)
end

describe('rendered text search command primitives', function()
    describe('query normalization', function()
        it('requires a table before reading query fields', function()
            for _, value in ipairs({false, 'Ready', 4}) do
                assert_error('text search query must be a table', function()
                    text_search.normalize_query(value)
                end)
            end
            assert_error('text search query must be a table', function()
                text_search.normalize_query(nil)
            end)
        end)

        it('rejects unknown fields and names the offending field', function()
            assert_error(
                'text search query contains unknown field: pattern',
                function()
                    text_search.normalize_query({
                        text='Ready',
                        pattern=false,
                    })
                end)
        end)

        it('requires nonempty string text', function()
            for _, query in ipairs({
                {},
                {text=false},
                {text=12},
                {text=''},
            }) do
                assert_error(
                    'text search query.text must be a nonempty string',
                    function()
                        text_search.normalize_query(query)
                    end)
            end
        end)

        it('rejects each unsupported control byte explicitly', function()
            local cases = {
                {
                    text='left\0right',
                    message='text search query.text must not contain NUL bytes',
                },
                {
                    text='left\rright',
                    message='text search query.text must not contain ' ..
                        'carriage-return bytes',
                },
                {
                    text='left\nright',
                    message='text search query.text must not contain ' ..
                        'newline bytes',
                },
            }
            for _, case in ipairs(cases) do
                assert_error(case.message, function()
                    text_search.normalize_query({text=case.text})
                end)
            end
        end)

        it('defaults occurrence to one and accepts positive integers',
                function()
            assert.same({
                text='Ready',
                occurrence=1,
            }, text_search.normalize_query({text='Ready'}))
            assert.same({
                text='Ready',
                occurrence=3,
            }, text_search.normalize_query({
                text='Ready',
                occurrence=3,
            }))
        end)

        it('rejects non-positive and non-integral occurrences', function()
            for _, occurrence in ipairs({
                false,
                '2',
                -1,
                0,
                1.5,
                math.huge,
            }) do
                assert_error(
                    'text search query.occurrence must be a positive integer',
                    function()
                        text_search.normalize_query({
                            text='Ready',
                            occurrence=occurrence,
                        })
                    end)
            end
        end)

        it('returns a copy insulated from caller mutation', function()
            local query = {
                text='Ready',
                occurrence=2,
            }
            local normalized = text_search.normalize_query(query)
            query.text = 'Changed'
            query.occurrence = 9
            assert.same({
                text='Ready',
                occurrence=2,
            }, normalized)
            assert.not_equals(query, normalized)
        end)
    end)

    describe('rectangle normalization', function()
        it('requires a rectangle table', function()
            assert_error('search area must be a table', function()
                text_search.normalize_rectangle(false, 'search area')
            end)
        end)

        it('requires every coordinate to be an integer', function()
            local cases = {
                {field='x1', value=nil},
                {field='y1', value='0'},
                {field='x2', value=3.5},
                {field='y2', value=false},
            }
            for _, case in ipairs(cases) do
                local rectangle = {x1=0, y1=0, x2=4, y2=4}
                rectangle[case.field] = case.value
                assert_error(
                    'search area.' .. case.field .. ' must be an integer',
                    function()
                        text_search.normalize_rectangle(
                            rectangle, 'search area')
                    end)
            end
        end)

        it('accepts negative, zero, and positive boundary coordinates',
                function()
            assert.same({
                x1=-4,
                y1=0,
                x2=0,
                y2=7,
            }, text_search.normalize_rectangle({
                x1=-4,
                y1=0,
                x2=0,
                y2=7,
            }))
        end)

        it('rejects horizontal and vertical inversion separately',
                function()
            assert_error(
                'text search rectangle must not be horizontally inverted',
                function()
                    text_search.normalize_rectangle({
                        x1=2,
                        y1=0,
                        x2=1,
                        y2=3,
                    })
                end)
            assert_error(
                'text search rectangle must not be vertically inverted',
                function()
                    text_search.normalize_rectangle({
                        x1=0,
                        y1=3,
                        x2=2,
                        y2=2,
                    })
                end)
        end)

        it('returns a copy insulated from caller mutation', function()
            local rectangle = {x1=1, y1=2, x2=3, y2=4}
            local normalized =
                text_search.normalize_rectangle(rectangle)
            rectangle.x1 = 20
            assert.same({x1=1, y1=2, x2=3, y2=4}, normalized)
            assert.not_equals(rectangle, normalized)
        end)
    end)

    describe('inclusive rectangle intersection', function()
        it('returns a fresh partial intersection without mutating inputs',
                function()
            local first = {x1=0, y1=1, x2=8, y2=6}
            local second = {x1=3, y1=-2, x2=10, y2=4}
            assert.same({
                x1=3,
                y1=1,
                x2=8,
                y2=4,
            }, text_search.intersect_rectangles(first, second))
            assert.same({x1=0, y1=1, x2=8, y2=6}, first)
            assert.same({x1=3, y1=-2, x2=10, y2=4}, second)
        end)

        it('preserves inclusive edge and point intersections', function()
            assert.same({
                x1=2,
                y1=1,
                x2=2,
                y2=3,
            }, text_search.intersect_rectangles(
                {x1=0, y1=0, x2=2, y2=3},
                {x1=2, y1=1, x2=4, y2=5}))
            assert.same({
                x1=2,
                y1=3,
                x2=2,
                y2=3,
            }, text_search.intersect_rectangles(
                {x1=0, y1=0, x2=2, y2=3},
                {x1=2, y1=3, x2=2, y2=3}))
        end)

        it('returns one distinct sentinel for empty intersections',
                function()
            local horizontal = text_search.intersect_rectangles(
                {x1=0, y1=0, x2=1, y2=1},
                {x1=2, y1=0, x2=3, y2=1})
            local vertical = text_search.intersect_rectangles(
                {x1=0, y1=0, x2=1, y2=1},
                {x1=0, y1=2, x2=1, y2=3})
            assert.is_true(text_search.is_empty_intersection(horizontal))
            assert.is_true(text_search.is_empty_intersection(vertical))
            assert.equals(text_search.EMPTY_INTERSECTION, horizontal)
            assert.equals(horizontal, vertical)
            assert.is_false(text_search.is_empty_intersection(nil))
            assert.is_false(text_search.is_empty_intersection({}))
        end)

        it('validates both operands before intersecting', function()
            assert_error(
                'first text search rectangle.x1 must be an integer',
                function()
                    text_search.intersect_rectangles(
                        {x1=false, y1=0, x2=1, y2=1},
                        {x1=0, y1=0, x2=1, y2=1})
                end)
            assert_error(
                'second text search rectangle must not be vertically inverted',
                function()
                    text_search.intersect_rectangles(
                        {x1=0, y1=0, x2=1, y2=1},
                        {x1=0, y1=2, x2=1, y2=1})
                end)
        end)
    end)
end)
