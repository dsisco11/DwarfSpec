-- Unit contracts for file-suite base-screen focus pollution detection.

local EComparison =
    require('dwarfspec.protocol.diagnostics.base_screen_focus_comparisons')
local EventType = require('dwarfspec.protocol.enums.event_types')
local FileSuiteIdentity =
    require('dwarfspec.host.execution.file_suite_identity')

local host = assert(loadfile(
    'src/dwarfspec/host/execution/host.lua'))()
local adapter = assert(loadfile(
    'src/dwarfspec/host/execution/busted_lifecycle_adapter.lua'))()
local execute_path = '.luarocks/share/lua/5.4/busted/execute.lua'

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

---Executes all registered files through the pinned Busted runtime.
---@param busted table
---@param repeats integer|nil
local function execute(busted, repeats)
    assert(loadfile(execute_path))()(busted)(repeats or 1, {
        seed=1,
        shuffle=false,
        sort=false,
    })
end

---Creates one file-suite identity for direct lifecycle tests.
---@param name string
---@param instance integer
---@return DwarfSpecFileSuiteIdentity
local function identity(name, instance)
    return FileSuiteIdentity.new({
        suite_id=name .. '#repeat=1#instance=' .. tostring(instance),
        suite_name=name,
        source_identity=name,
        repeat_index=1,
        repeat_count=1,
    })
end

---Creates a detached change diagnostic.
---@param before table
---@param after table
---@return table
local function change_diagnostic(before, after)
    return {
        kind='base_screen_focus_changed',
        content={
            severity='warning',
            screen_comparison=EComparison.CHANGED,
            focus_comparison=EComparison.SAME,
            details_complete=true,
            before={
                screen={status='present', type=before.value},
                focus={status='available', values={}},
            },
            after={
                screen={status='present', type=after.value},
                focus={status='available', values={}},
            },
        },
    }
end

---Creates a guard over one mutable representative base-screen state.
---@param state table
---@return table, table[], table[]
local function state_guard(state)
    local captures = {}
    local comparisons = {}
    return {
        capture=function()
            local observation = {value=state.value}
            if state.mounts ~= nil then
                observation.mounts = {}
                for category, count in pairs(state.mounts) do
                    observation.mounts[category] = count
                end
            end
            table.insert(captures, observation)
            return observation
        end,
        compare=function(_, before, after)
            table.insert(comparisons, {before=before, after=after})
            if before.value == after.value then return nil end
            return change_diagnostic(before, after)
        end,
    }, captures, comparisons
end

---Installs the production focus lifecycle on one Busted runtime.
---@param busted table
---@param state table
---@param reset function|nil
---@return table, table[], table[], table[]
local function install(busted, state, reset)
    local guard, captures, comparisons = state_guard(state)
    local published = {}
    local run = {
        event_publisher={
            publish=function(event_type, payload)
                assert.equals(EventType.DIAGNOSTIC_RECORDED, event_type)
                table.insert(published, payload)
            end,
        },
    }
    local lifecycle = host.new_focus_lifecycle(
        run, reset or function() end, guard)
    adapter.install(busted, {
        project_root='.',
        on_suite_entry=lifecycle.suite_entry,
        on_suite_exit=lifecycle.suite_exit,
        on_test_start=lifecycle.test_start,
    })
    host.install_ds_example_entry(adapter, busted, lifecycle)
    host.install_ds_example_exit(adapter, busted, lifecycle)
    busted.export('state', state)
    return lifecycle, published, captures, comparisons
end

---Returns diagnostics with one requested lifecycle scope.
---@param diagnostics table[]
---@param scope string
---@return table[]
local function diagnostics_for(diagnostics, scope)
    local selected = {}
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.content.scope == scope then
            table.insert(selected, diagnostic)
        end
    end
    return selected
end

describe('file-suite focus lifecycle', function()
    it('allows suite setup state that teardown restores to S0', function()
        local busted = new_busted()
        local state = {value='inherited'}
        local _, published, captures = install(busted, state)
        register_file(busted, 'tests/restored_setup_spec.lua', [[
            setup(function() state.value = 'working' end)
            teardown(function() state.value = 'inherited' end)
            it('uses suite state', function() end)
        ]])

        execute(busted)

        assert.equals(0, #published)
        assert.same(
            {'inherited', 'working', 'working', 'inherited'},
            {
                captures[1].value,
                captures[2].value,
                captures[3].value,
                captures[4].value,
            })
    end)

    it('detects every file mutation source at S2', function()
        local scenarios = {
            {
                name='file body',
                source=[[
                    state.value = 'leaked'
                    it('runs', function() end)
                ]],
            },
            {
                name='strict setup',
                source=[[
                    setup(function() state.value = 'leaked' end)
                    it('runs', function() end)
                ]],
            },
            {
                name='lazy setup',
                source=[[
                    lazy_setup(function() state.value = 'leaked' end)
                    it('runs', function() end)
                ]],
            },
            {
                name='example',
                source=[[
                    it('runs', function() state.value = 'leaked' end)
                ]],
            },
            {
                name='lazy teardown',
                source=[[
                    lazy_teardown(function() state.value = 'leaked' end)
                    it('runs', function() end)
                ]],
            },
            {
                name='strict teardown',
                source=[[
                    teardown(function() state.value = 'leaked' end)
                    it('runs', function() end)
                ]],
            },
        }

        for _, scenario in ipairs(scenarios) do
            local busted = new_busted()
            local state = {value='inherited'}
            local _, published = install(busted, state)
            local file_name = 'tests/' ..
                scenario.name:gsub(' ', '_') .. '_spec.lua'
            register_file(busted, file_name, scenario.source)

            execute(busted)

            local suite = diagnostics_for(published, 'suite')
            assert.equals(1, #suite, scenario.name)
            assert.equals('file', suite[1].content.attribution)
            assert.equals(file_name, suite[1].content.suite_name)
            assert.equals(file_name, suite[1].content.source_identity)
            assert.equals(1, suite[1].content.repeat_index)
        end
    end)

    it('does not create suite records for nested contexts', function()
        local busted = new_busted()
        local state = {value='same'}
        local _, published, _, comparisons = install(busted, state)
        register_file(busted, 'tests/nested_clean_spec.lua', [[
            describe('outer', function()
                context('inner', function()
                    it('runs', function() end)
                end)
            end)
        ]])

        execute(busted)

        assert.equals(0, #published)
        assert.equals(2, #comparisons)
    end)

    it('attributes one leak and gives the next file its actual S0', function()
        local busted = new_busted()
        local state = {value='original'}
        local _, published, captures = install(busted, state)
        register_file(busted, 'tests/first_leak_spec.lua', [[
            state.value = 'inherited leak'
            it('runs', function() end)
        ]])
        register_file(busted, 'tests/second_observer_spec.lua', [[
            it('runs', function() end)
        ]])

        execute(busted)

        local suite = diagnostics_for(published, 'suite')
        assert.equals(1, #suite)
        assert.equals(
            'tests/first_leak_spec.lua', suite[1].content.suite_name)
        assert.equals('inherited leak', captures[5].value)
        assert.equals('inherited leak', captures[8].value)
    end)

    it('publishes one example and one file warning for a persistent leak',
            function()
        local busted = new_busted()
        local state = {value='original'}
        local _, published = install(busted, state)
        register_file(busted, 'tests/persistent_nested_spec.lua', [[
            describe('outer', function()
                context('inner', function()
                    it('leaks', function()
                        state.value = 'persistent leak'
                    end)
                end)
            end)
        ]])

        execute(busted)

        assert.equals(1, #diagnostics_for(published, 'example'))
        assert.equals(1, #diagnostics_for(published, 'suite'))
        assert.equals(2, #published)
    end)

    it('retains example warnings when later work restores S0', function()
        local scenarios = {
            {
                name='later example',
                source=[[
                    it('leaks', function() state.value = 'leak' end)
                    it('restores', function() state.value = 'original' end)
                ]],
                example_warnings=2,
            },
            {
                name='file teardown',
                source=[[
                    teardown(function() state.value = 'original' end)
                    it('leaks', function() state.value = 'leak' end)
                ]],
                example_warnings=1,
            },
        }

        for _, scenario in ipairs(scenarios) do
            local busted = new_busted()
            local state = {value='original'}
            local _, published = install(busted, state)
            register_file(busted, 'tests/restored_' ..
                scenario.name:gsub(' ', '_') .. '_spec.lua',
                scenario.source)

            execute(busted)

            assert.equals(scenario.example_warnings,
                #diagnostics_for(published, 'example'), scenario.name)
            assert.equals(
                0, #diagnostics_for(published, 'suite'), scenario.name)
        end
    end)

    it('cleans suite setup and teardown mounts before S2', function()
        local busted = new_busted()
        local state = {
            value='same',
            mounts={
                widget=0,
                overlay=0,
                screen=0,
                native_attachment=0,
            },
        }
        local reset_reasons = {}
        local _, published, captures = install(
            busted, state, function(reason)
                table.insert(reset_reasons, reason)
                for category in pairs(state.mounts) do
                    state.mounts[category] = 0
                end
            end)
        busted.export('mounts', state.mounts)
        register_file(busted, 'tests/suite_mounts_spec.lua', [[
            local function mount_all()
                for category in pairs(mounts) do mounts[category] = 1 end
            end
            setup(mount_all)
            teardown(mount_all)
            it('runs', function() end)
        ]])

        execute(busted)

        assert.equals(0, #published)
        assert.same({
            'before example',
            'after example',
            'after suite',
        }, reset_reasons)
        assert.same({
            widget=0,
            overlay=0,
            screen=0,
            native_attachment=0,
        }, state.mounts)
        assert.equals('same', captures[4].value)
        assert.same({
            widget=0,
            overlay=0,
            screen=0,
            native_attachment=0,
        }, captures[4].mounts)
    end)

    it('uses independent S0 and S2 records for every repeat', function()
        local busted = new_busted()
        local state = {value=0}
        local _, published, captures = install(busted, state)
        register_file(busted, 'tests/repeated_leak_spec.lua', [[
            state.value = state.value + 1
            it('runs', function() end)
        ]])

        execute(busted, 2)

        local suite = diagnostics_for(published, 'suite')
        assert.equals(2, #suite)
        assert.equals(1, suite[1].content.repeat_index)
        assert.equals(2, suite[2].content.repeat_index)
        assert.equals(0, captures[1].value)
        assert.equals(1, captures[4].value)
        assert.equals(1, captures[5].value)
        assert.equals(2, captures[8].value)
    end)

    it('releases suite guards across failure and empty-file paths',
            function()
        local busted = new_busted()
        local state = {value='original'}
        local _, published = install(busted, state)
        register_file(busted, 'tests/body_failure_spec.lua', [[
            state.value = 'body failure'
            error('body failure')
        ]])
        register_file(busted, 'tests/setup_failure_spec.lua', [[
            setup(function()
                state.value = 'setup failure'
                error('setup failure')
            end)
            it('does not run', function() end)
        ]])
        register_file(busted, 'tests/example_failure_spec.lua', [[
            it('fails', function()
                state.value = 'example failure'
                error('example failure')
            end)
        ]])
        register_file(busted, 'tests/teardown_failure_spec.lua', [[
            teardown(function()
                state.value = 'teardown failure'
                error('teardown failure')
            end)
            it('runs', function() end)
        ]])
        register_file(busted, 'tests/pending_only_spec.lua', [[
            pending('not runnable')
        ]])
        register_file(busted, 'tests/following_clean_spec.lua', [[
            it('runs', function() end)
        ]])

        execute(busted)

        local suite = diagnostics_for(published, 'suite')
        assert.equals(4, #suite)
        assert.same({
            'tests/body_failure_spec.lua',
            'tests/setup_failure_spec.lua',
            'tests/example_failure_spec.lua',
            'tests/teardown_failure_spec.lua',
        }, {
            suite[1].content.suite_name,
            suite[2].content.suite_name,
            suite[3].content.suite_name,
            suite[4].content.suite_name,
        })
    end)

    it('skips S2 and releases private state after suite reset failure',
            function()
        local state = {value='same'}
        local guard, captures, comparisons = state_guard(state)
        local reset_count = 0
        local lifecycle = host.new_focus_lifecycle({
            event_publisher={publish=function() end},
        }, function(reason)
            assert.equals('after suite', reason)
            reset_count = reset_count + 1
            if reset_count == 1 then error('suite settlement failed') end
        end, guard)
        local first = identity('tests/failed_reset_spec.lua', 1)
        local first_state = lifecycle.suite_entry(first)

        assert.has_error(function()
            lifecycle.suite_exit(first, first_state)
        end, 'suite settlement failed')
        lifecycle.suite_exit(first, first_state)

        assert.equals(1, reset_count)
        assert.equals(1, #captures)
        assert.equals(0, #comparisons)

        local second = identity('tests/following_spec.lua', 2)
        local second_state = lifecycle.suite_entry(second)
        lifecycle.suite_exit(second, second_state)

        assert.equals(2, reset_count)
        assert.equals(3, #captures)
        assert.equals(1, #comparisons)
    end)

    it('clears active suite state during emergency cleanup', function()
        local state = {value='same'}
        local guard, captures, comparisons = state_guard(state)
        local reset_count = 0
        local lifecycle = host.new_focus_lifecycle({
            event_publisher={publish=function() end},
        }, function()
            reset_count = reset_count + 1
        end, guard)
        local current = identity('tests/aborted_spec.lua', 1)
        local current_state = lifecycle.suite_entry(current)

        lifecycle.clear()
        lifecycle.suite_exit(current, current_state)

        assert.equals(0, reset_count)
        assert.equals(1, #captures)
        assert.equals(0, #comparisons)
    end)
end)
