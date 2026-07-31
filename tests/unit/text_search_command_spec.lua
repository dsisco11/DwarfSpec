-- Unit contracts for the rendered-text search command primitives.

local text_search = require('dwarfspec.commands.text_search')

---Asserts that one callback fails with an exact message.
---@param message string
---@param callback function
local function assert_error(message, callback)
    assert.has_error(callback, message)
end

---Constructs a command harness that records screen dependency calls.
---@param width integer
---@param height integer
---@param reader fun(x:integer, y:integer):any
---@return function, table
local function command_harness(width, height, reader)
    local observations = {
        reads={},
        window_calls=0,
    }
    local command = text_search.new({
        get_window_size=function()
            observations.window_calls = observations.window_calls + 1
            return width, height
        end,
        read_tile=function(x, y)
            observations.reads[#observations.reads + 1] = {x=x, y=y}
            return reader(x, y)
        end,
    })
    return command, observations
end

---Constructs a readable byte-screen command from equal-width row strings.
---@param rows string[]
---@return function, table
local function text_screen(rows)
    local width = #rows[1]
    for _, row in ipairs(rows) do assert.equals(width, #row) end
    return command_harness(width, #rows, function(x, y)
        local ch = rows[y + 1]:byte(x + 1)
        return ch and {ch=ch} or nil
    end)
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

    describe('rendered-cell matching', function()
        it('requires callable screen dependencies', function()
            assert_error(
                'text search command requires dependencies',
                function() text_search.new(nil) end)
            assert_error(
                'text search command requires window-size access',
                function() text_search.new({}) end)
            assert_error(
                'text search command requires tile-reading access',
                function()
                    text_search.new({get_window_size=function() end})
                end)
            assert_error(
                'text search window-size access must be a function',
                function()
                    text_search.new({
                        get_window_size=true,
                        read_tile=function() end,
                    })
                end)
            assert_error(
                'text search tile-reading access must be a function',
                function()
                    text_search.new({
                        get_window_size=function() end,
                        read_tile=true,
                    })
                end)
        end)

        it('captures window dimensions once and reads only clipped cells',
                function()
            local command, observations =
                command_harness(5, 4, function() return {ch=32} end)
            assert.is_nil(command({text='missing'}, {
                x1=-2,
                y1=1,
                x2=9,
                y2=2,
            }))
            assert.equals(1, observations.window_calls)
            assert.equals(10, #observations.reads)
            assert.same({x=0, y=1}, observations.reads[1])
            assert.same({x=4, y=2},
                observations.reads[#observations.reads])
            for _, coordinate in ipairs(observations.reads) do
                assert.is_true(coordinate.x >= 0 and coordinate.x <= 4)
                assert.is_true(coordinate.y >= 1 and coordinate.y <= 2)
            end
        end)

        it('rejects invalid captured window dimensions before reading',
                function()
            local reads = 0
            local command = text_search.new({
                get_window_size=function() return 0, 4 end,
                read_tile=function()
                    reads = reads + 1
                    return {ch=32}
                end,
            })
            assert_error(
                'text search received invalid window dimensions: ' ..
                    'width=0 height=4',
                function()
                    command({text='x'}, {x1=0, y1=0, x2=1, y2=1})
                end)
            assert.equals(0, reads)
        end)

        it('returns the empty sentinel without reading disjoint scopes',
                function()
            local command, observations =
                command_harness(3, 2, function() return {ch=32} end)
            local result = command(
                {text='x'}, {x1=3, y1=0, x2=6, y2=1})
            assert.is_true(text_search.is_empty_intersection(result))
            assert.equals(1, observations.window_calls)
            assert.equals(0, #observations.reads)
        end)

        it('finds text at both horizontal edges', function()
            local command = text_screen({'ABC...XYZ'})
            assert.same({x1=0, y1=0, x2=2, y2=0},
                command({text='ABC'}, {x1=0, y1=0, x2=8, y2=0}))
            assert.same({x1=6, y1=0, x2=8, y2=0},
                command({text='XYZ'}, {x1=0, y1=0, x2=8, y2=0}))
        end)

        it('returns exact bounds for single-cell text', function()
            local command = text_screen({' A '})
            assert.same({x1=1, y1=0, x2=1, y2=0},
                command({text='A'}, {x1=0, y1=0, x2=2, y2=0}))
        end)

        it('orders occurrences by row before column', function()
            local command = text_screen({'.....A', 'A.....'})
            local scope = {x1=0, y1=0, x2=5, y2=1}
            assert.same({x1=5, y1=0, x2=5, y2=0},
                command({text='A'}, scope))
            assert.same({x1=0, y1=1, x2=0, y2=1},
                command({text='A', occurrence=2}, scope))
        end)

        it('selects repeated occurrences from left to right', function()
            local command = text_screen({'cat cat cat'})
            assert.same({x1=8, y1=0, x2=10, y2=0},
                command(
                    {text='cat', occurrence=3},
                    {x1=0, y1=0, x2=10, y2=0}))
        end)

        it('counts overlapping occurrences one cell apart', function()
            local command = text_screen({'aaaa'})
            assert.same({x1=2, y1=0, x2=3, y2=0},
                command(
                    {text='aa', occurrence=3},
                    {x1=0, y1=0, x2=3, y2=0}))
        end)

        it('stops before reading rows after the selected occurrence',
                function()
            local command, observations =
                text_screen({'A...', '....', '....'})
            assert.same({x1=0, y1=0, x2=0, y2=0},
                command({text='A'}, {x1=0, y1=0, x2=3, y2=2}))
            assert.equals(4, #observations.reads)
            for _, coordinate in ipairs(observations.reads) do
                assert.equals(0, coordinate.y)
            end
        end)

        it('does not match text clipped by the effective scope',
                function()
            local command = text_screen({'HELLO'})
            assert.is_nil(command(
                {text='HELLO'}, {x1=1, y1=0, x2=4, y2=0}))
            assert.same({x1=1, y1=0, x2=3, y2=0},
                command({text='ELL'}, {x1=1, y1=0, x2=3, y2=0}))
        end)

        it('breaks matches across unreadable cells', function()
            local command = command_harness(3, 1, function(x)
                if x == 0 then return {ch=string.byte('A')} end
                if x == 2 then return {ch=string.byte('B')} end
                return nil
            end)
            assert.is_nil(command(
                {text='AB'}, {x1=0, y1=0, x2=2, y2=0}))
        end)

        it('treats every invalid character value as unreadable',
                function()
            local pens = {
                [2]={},
                [3]={fg=7},
                [4]={ch=1.5},
                [5]={ch=-1},
                [6]={ch=256},
            }
            local command = command_harness(6, 1, function(x)
                return pens[x + 1]
            end)
            assert_error(
                'text search effective region has no readable screen cells: ' ..
                    '{x1=0,y1=0,x2=5,y2=0}',
                function()
                    command({text='A'}, {x1=0, y1=0, x2=5, y2=0})
                end)
        end)

        it('preserves a readable NUL byte as a nonmatching cell',
                function()
            local command = command_harness(
                1, 1, function() return {ch=0} end)
            assert.is_nil(command(
                {text='A'}, {x1=0, y1=0, x2=0, y2=0}))
        end)

        it('matches the inclusive maximum byte value exactly', function()
            local command = command_harness(
                1, 1, function() return {ch=255} end)
            assert.same({x1=0, y1=0, x2=0, y2=0},
                command(
                    {text=string.char(255)},
                    {x1=0, y1=0, x2=0, y2=0}))
        end)

        it('ignores pen styling, tiles, and unrelated text fields',
                function()
            local command = command_harness(1, 1, function()
                return {
                    ch=string.byte('A'),
                    fg=2,
                    bg=4,
                    tile=987,
                    text='not A',
                }
            end)
            local result = command(
                {text='A'}, {x1=0, y1=0, x2=0, y2=0})
            assert.same({x1=0, y1=0, x2=0, y2=0}, result)
            assert.is_nil(getmetatable(result))
        end)

        it('returns a fresh plain rectangle for every match', function()
            local command = text_screen({'A'})
            local scope = {x1=0, y1=0, x2=0, y2=0}
            local first = command({text='A'}, scope)
            local second = command({text='A'}, scope)
            assert.same(first, second)
            assert.not_equals(first, second)
            first.x1 = 9
            assert.equals(0, second.x1)
        end)

        it('uses the query copy when a dependency mutates its caller',
                function()
            local query = {text='A', occurrence=1}
            local command = text_search.new({
                get_window_size=function()
                    query.text = 'B'
                    query.occurrence = 2
                    return 1, 1
                end,
                read_tile=function() return {ch=string.byte('A')} end,
            })
            assert.same({x1=0, y1=0, x2=0, y2=0},
                command(query, {x1=0, y1=0, x2=0, y2=0}))
            assert.same({text='B', occurrence=2}, query)
        end)

        it('returns nil for a readable region without the occurrence',
                function()
            local command = text_screen({'ABC'})
            assert.is_nil(command(
                {text='Z'}, {x1=0, y1=0, x2=2, y2=0}))
            assert.is_nil(command(
                {text='A', occurrence=2},
                {x1=0, y1=0, x2=2, y2=0}))
        end)

        it('characterizes a full 128 by 64 miss without a time gate',
                function()
            local command, observations =
                command_harness(128, 64, function() return {ch=32} end)
            assert.is_nil(command(
                {text='not present'},
                {x1=0, y1=0, x2=127, y2=63}))
            assert.equals(1, observations.window_calls)
            assert.equals(128 * 64, #observations.reads)
        end)
    end)
end)
