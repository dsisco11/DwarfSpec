local adapter_path =
    'src/dwarfspec/automation/busted_lifecycle_adapter.lua'
local execute_path = '.luarocks/share/lua/5.4/busted/execute.lua'

describe('Busted file lifecycle adapter', function()
    local adapter

    before_each(function()
        adapter = assert(loadfile(adapter_path))()
    end)

    ---Creates one isolated real Busted 2.3.0 runtime.
    ---@return table
    local function new_busted()
        local busted = require('busted.core')()
        local init_path = assert(package.searchpath('busted', package.path))
        assert(loadfile(init_path))()(busted)
        busted.randomize = false
        busted.sort = false
        busted.randomseed = 1
        return busted
    end

    ---Registers one in-memory spec file on a real Busted runtime.
    ---@param busted table
    ---@param file_name string
    ---@param source string
    local function register_file(busted, file_name, source)
        local body = assert(load(source, '@' .. file_name))
        local callable = setmetatable({
            getTrace=function(_, trace) return trace end,
            rewriteMessage=function(_, message) return message end,
        }, {__call=body})
        busted.executors.file(file_name, callable)
    end

    ---Executes all registered files through the pinned real Busted runtime.
    ---@param busted table
    ---@param repeats integer|nil
    local function execute(busted, repeats)
        assert(loadfile(execute_path))()(busted)(repeats or 1, {
            seed=1,
            shuffle=false,
            sort=false,
        })
    end

    ---Installs the adapter and appends detached callback records to a journal.
    ---@param busted table
    ---@param journal table[]
    ---@param entry function|nil
    ---@param exit function|nil
    local function install(busted, journal, entry, exit)
        busted.export('journal', journal)
        adapter.install(busted, {
            project_root='.',
            on_suite_entry=function(identity)
                table.insert(journal, {
                    event='entry',
                    identity=identity,
                })
                if entry then return entry(identity) end
                return identity.suite_id
            end,
            on_suite_exit=function(identity, state)
                table.insert(journal, {
                    event='exit',
                    identity=identity,
                    state=state,
                })
                if exit then exit(identity, state) end
            end,
        })
    end

    it('brackets the complete file body and teardown boundary', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal,
            function()
                table.insert(journal, {event='entry callback'})
            end,
            function()
                table.insert(journal, {event='exit callback'})
            end)
        register_file(busted, 'tests/fixture/ordered_spec.lua', [[
            table.insert(journal, {event='file body'})
            setup(function()
                table.insert(journal, {event='file strict setup'})
            end)
            lazy_setup(function()
                table.insert(journal, {event='file lazy setup'})
            end)
            teardown(function()
                table.insert(journal, {event='file strict teardown'})
            end)
            lazy_teardown(function()
                table.insert(journal, {event='file lazy teardown'})
            end)
            describe('nested', function()
                table.insert(journal, {event='nested body'})
                setup(function()
                    table.insert(journal, {event='nested strict setup'})
                end)
                lazy_setup(function()
                    table.insert(journal, {event='nested lazy setup'})
                end)
                teardown(function()
                    table.insert(journal, {event='nested strict teardown'})
                end)
                lazy_teardown(function()
                    table.insert(journal, {event='nested lazy teardown'})
                end)
                it('runs', function()
                    table.insert(journal, {event='example'})
                end)
            end)
        ]])

        execute(busted)

        local events = {}
        for _, item in ipairs(journal) do
            table.insert(events, item.event)
        end
        assert.same({
            'entry',
            'entry callback',
            'file body',
            'file strict setup',
            'nested body',
            'nested strict setup',
            'file lazy setup',
            'nested lazy setup',
            'example',
            'nested lazy teardown',
            'nested strict teardown',
            'file lazy teardown',
            'file strict teardown',
            'exit',
            'exit callback',
        }, events)
    end)

    it('captures entry before and exit after arbitrary file state changes',
            function()
        local busted = new_busted()
        local journal = {}
        local state = {value='initial'}
        local entry_state
        local exit_state
        busted.export('state', state)
        install(busted, journal,
            function()
                entry_state = state.value
            end,
            function()
                exit_state = state.value
            end)
        register_file(busted, 'tests/state_spec.lua', [[
            state.value = 'file body'
            teardown(function() state.value = 'strict teardown' end)
            it('runs', function() state.value = 'example' end)
        ]])

        execute(busted)

        assert.equals('initial', entry_state)
        assert.equals('strict teardown', exit_state)
    end)

    it('does not create suite records for nested contexts', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal)
        register_file(busted, 'tests/nested_spec.lua', [[
            describe('outer', function()
                context('inner', function()
                    it('runs', function() end)
                end)
            end)
        ]])

        execute(busted)

        assert.equals(2, #journal)
        assert.equals('entry', journal[1].event)
        assert.equals('exit', journal[2].event)
        assert.equals(journal[1].identity.suite_id,
            journal[2].identity.suite_id)
    end)

    it('executes two files as sequential nonoverlapping suites', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal)
        register_file(busted, 'tests/first_spec.lua', [[
            it('first', function()
                table.insert(journal, {event='first example'})
            end)
        ]])
        register_file(busted, 'tests/second_spec.lua', [[
            it('second', function()
                table.insert(journal, {event='second example'})
            end)
        ]])

        execute(busted)

        local events = {}
        for _, item in ipairs(journal) do
            table.insert(events, item.event)
        end
        assert.same({
            'entry',
            'first example',
            'exit',
            'entry',
            'second example',
            'exit',
        }, events)
        assert.same({
            suite_id='tests/first_spec.lua#repeat=1#instance=1',
            suite_name='tests/first_spec.lua',
            source_identity='tests/first_spec.lua',
            repeat_index=1,
            repeat_count=1,
        }, journal[1].identity)
        assert.equals('tests/second_spec.lua',
            journal[4].identity.suite_name)
        assert.not_equals(journal[1].identity.suite_id,
            journal[4].identity.suite_id)
    end)

    it('releases a filtered file with no runnable examples', function()
        local busted = new_busted()
        local journal = {}
        local example_count = 0
        install(busted, journal)
        busted.subscribe({'test', 'start'}, function()
            example_count = example_count + 1
        end)
        require('busted.modules.filter_loader')()(busted, {
            excludeTags={},
            tags={},
            filter={'selected name'},
            name={},
            filterOut={},
        })
        register_file(busted, 'tests/filtered_spec.lua', [[
            it('excluded name', function() end)
        ]])

        execute(busted)

        assert.equals(0, example_count)
        assert.equals(2, #journal)
        assert.equals('entry', journal[1].event)
        assert.equals('exit', journal[2].event)
    end)

    it('releases a file containing only a pending declaration', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal)
        register_file(busted, 'tests/pending_spec.lua', [[
            pending('not runnable')
        ]])

        execute(busted)

        assert.equals(2, #journal)
        assert.equals('entry', journal[1].event)
        assert.equals('exit', journal[2].event)
        assert.equals(journal[1].identity.suite_id,
            journal[2].identity.suite_id)
    end)

    it('releases file identity after setup and teardown failures', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal)
        register_file(busted, 'tests/failing_spec.lua', [[
            setup(function() error('setup failure') end)
            teardown(function() error('teardown failure') end)
            it('does not run', function() end)
        ]])
        register_file(busted, 'tests/following_spec.lua', [[
            it('runs', function()
                table.insert(journal, {event='following example'})
            end)
        ]])

        execute(busted)

        assert.equals('entry', journal[1].event)
        assert.equals('exit', journal[2].event)
        assert.equals('entry', journal[3].event)
        assert.equals('following example', journal[4].event)
        assert.equals('exit', journal[5].event)
        assert.equals('tests/following_spec.lua',
            journal[3].identity.suite_name)
    end)

    it('creates independent file suites for every repeat', function()
        local busted = new_busted()
        local journal = {}
        install(busted, journal)
        register_file(busted, 'tests/repeated_spec.lua', [[
            it('runs', function() end)
        ]])

        execute(busted, 3)

        assert.equals(6, #journal)
        local suite_ids = {}
        for index = 1, 3 do
            local entry = journal[index * 2 - 1]
            local exit = journal[index * 2]
            assert.equals('entry', entry.event)
            assert.equals('exit', exit.event)
            assert.equals(index, entry.identity.repeat_index)
            assert.equals(3, entry.identity.repeat_count)
            assert.equals(entry.identity.suite_id, exit.identity.suite_id)
            assert.equals(entry.identity.suite_id, exit.state)
            suite_ids[entry.identity.suite_id] = true
        end
        local unique_count = 0
        for _ in pairs(suite_ids) do unique_count = unique_count + 1 end
        assert.equals(3, unique_count)
    end)
end)
