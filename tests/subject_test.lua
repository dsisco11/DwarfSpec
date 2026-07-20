-- Unit contracts for synchronous fluent DwarfSpec subjects.

local subject_module = assert(loadfile('src/dwarfspec/subject.lua'))()

describe('DwarfSpec subject commands', function()
    it('routes fluent mutations and scalar observations through its context',
            function()
        local calls = {}
        local context = {
            subject_commands={
                click=function(_, button)
                    table.insert(calls, {'click', button})
                end,
                hover=function(_, anchor)
                    table.insert(calls, {'hover', anchor})
                end,
                move_pointer=function(_, anchor)
                    table.insert(calls, {'move_pointer', anchor})
                end,
                input=function(_, keys)
                    table.insert(calls, {'input', keys})
                end,
                type=function(_, text)
                    table.insert(calls, {'type', text})
                end,
                inspect=function()
                    table.insert(calls, {'inspect'})
                    return {text='saved'}
                end,
            },
            resolve_subject=function(_, _, operation)
                assert.equals('subject raw access', operation)
                return {view_id='status'}
            end,
        }
        local subject = subject_module.new(context, {id=9}, {})

        assert.equals(subject, subject:click('right'))
        assert.equals(subject, subject:hover('top_left'))
        assert.equals(subject, subject:move_pointer('center'))
        assert.equals(subject, subject:input('SELECT'))
        assert.equals(subject, subject:type('abc'))
        assert.same({text='saved'}, subject:inspect())
        assert.equals('saved', subject:text())
        assert.same({
            {'click', 'right'},
            {'hover', 'top_left'},
            {'move_pointer', 'center'},
            {'input', 'SELECT'},
            {'type', 'abc'},
            {'inspect'},
            {'inspect'},
        }, calls)
    end)

    it('rejects commands after its run-owned context is unavailable',
            function()
        local context = {subject_commands={}}
        local subject = subject_module.new(context, {id=1}, {})
        subject._references.context = nil

        assert.has_error(function() subject:click() end,
            'DwarfSpec subject is unavailable because its run has ended')
    end)
end)
