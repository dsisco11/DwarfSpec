-- Unit contracts for synchronous fluent DwarfSpec subjects.

local subject_module = assert(loadfile('src/dwarfspec/subject.lua'))()

---Creates one complete test subject descriptor.
---@param mount_id integer
---@return table
local function descriptor(mount_id)
    local adapter = {}
    local source = {adapter=adapter}
    return {
        mount_id=mount_id,
        source=source,
        path_segments={},
        adapter=adapter,
        captured_identity={},
        control_path_for_diagnostics='<root>',
    }
end

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
                redraw=function(_, options)
                    table.insert(calls, {'redraw', options})
                end,
                inspect=function()
                    table.insert(calls, {'inspect'})
                    return {text='saved'}
                end,
            },
            invoke_subject_command=function(self, selected, name, ...)
                return self.subject_commands[name](selected, ...)
            end,
            resolve_subject=function(_, _, operation)
                assert.equals('subject raw access', operation)
                return {view_id='status'}
            end,
        }
        local selected_descriptor = descriptor(9)
        local subject = subject_module.new(
            context, {id=9}, selected_descriptor)

        assert.equals(9, subject.mount_id)
        assert.equals('<root>', subject.control_path)
        assert.not_equals(selected_descriptor, subject._descriptor)
        assert.equals(selected_descriptor.source,
            subject._descriptor.source)
        assert.equals(selected_descriptor.captured_identity,
            subject._descriptor.captured_identity)
        assert.equals(subject, subject:click('right'))
        assert.same({{'click', 'right'}}, calls)
        assert.equals(subject, subject:hover('top_left'))
        assert.equals(subject, subject:move_pointer('center'))
        assert.equals(subject, subject:input('SELECT'))
        assert.equals(subject, subject:type('abc'))
        assert.equals(subject, subject:redraw())
        assert.equals(subject, subject:redraw({wait=false}))
        assert.same({text='saved'}, subject:inspect())
        assert.equals('saved', subject:text())
        assert.same({
            {'click', 'right'},
            {'hover', 'top_left'},
            {'move_pointer', 'center'},
            {'input', 'SELECT'},
            {'type', 'abc'},
            {'redraw', nil},
            {'redraw', {wait=false}},
            {'inspect'},
            {'inspect'},
        }, calls)
    end)

    it('rejects commands after its run-owned context is unavailable',
            function()
        local context = {subject_commands={}}
        local subject = subject_module.new(context, {id=1}, descriptor(1))
        subject._references.context = nil

        assert.has_error(function() subject:click() end,
            'DwarfSpec subject is unavailable because its run has ended')
        assert.has_error(function() subject:redraw() end,
            'DwarfSpec subject is unavailable because its run has ended')
    end)

    it('releases its adapter descriptor without mutating public identity',
            function()
        local context = {}
        local subject = subject_module.new(
            context, {id=4}, descriptor(4))

        assert.is_true(subject_module.release(subject))
        assert.is_false(subject_module.release(subject))
        assert.equals(4, subject.mount_id)
        assert.equals('<root>', subject.control_path)
        assert.is_nil(subject._descriptor)
    end)
end)
