-- Per-example and file-suite focus lifecycle.

local M = {}

---Creates focus observation and cleanup behavior for one active run.
---@param run table
---@param reset function
---@param guard table
---@param dependencies table
---@return table
function M.new(run, reset, guard, dependencies)
    assert(type(run) == 'table', 'focus lifecycle run is required')
    assert(type(reset) == 'function', 'focus lifecycle reset callback is required')
    assert(type(guard) == 'table' and type(guard.capture) == 'function' and
        type(guard.compare) == 'function', 'focus lifecycle guard is required')
    assert(type(run.event_publisher) == 'table' and
        type(run.event_publisher.publish) == 'function',
        'focus lifecycle event publisher is required')
    run.output_lines = run.output_lines or {}

    local lifecycle, active_suite, active_example = {}, nil, nil
    local function publish(diagnostic, scope, attribution, suite, example)
        if diagnostic == nil then return end
        diagnostic = dependencies.copy_json(diagnostic,
            'base-screen focus diagnostic')
        local content = diagnostic.content
        content.scope, content.attribution = scope, attribution
        content.suite_name, content.repeat_index =
            suite.suite_name, suite.repeat_index
        if example and example.example_name then
            content.example_name = example.example_name
        end
        local source
        if example ~= nil then
            source = example.source_identity
        else
            source = suite.source_identity
        end
        if source ~= nil then content.source_identity = source end
        run.event_publisher.publish(dependencies.event_type, diagnostic)
        if diagnostic.kind == dependencies.change_kind then
            table.insert(run.output_lines,
                dependencies.format_warning(diagnostic))
        end
    end

    ---Captures the initial state for one file-suite instance.
    ---@param identity table
    ---@return string
    function lifecycle.suite_entry(identity)
        assert(type(identity) == 'table' and type(identity.copy) == 'function',
            'focus lifecycle requires a file-suite identity')
        assert(active_suite == nil,
            'focus lifecycle already has an active file suite')
        active_example = nil
        active_suite = {identity=identity:copy(), before=guard:capture()}
        return active_suite.identity.suite_id
    end

    ---Cleans suite resources and publishes its focus comparison.
    ---@param identity table
    ---@param state any
    function lifecycle.suite_exit(identity, state)
        local completed = active_suite
        active_example, active_suite = nil, nil
        if completed == nil then return end
        assert(type(identity) == 'table' and
            identity.suite_id == completed.identity.suite_id,
            'focus lifecycle file-suite exit identity did not match entry')
        assert(state == nil or state == completed.identity.suite_id,
            'focus lifecycle file-suite state did not match entry')
        reset('after suite')
        publish(guard:compare(completed.before, guard:capture()),
            'suite', 'file', completed.identity)
    end

    ---Resets inherited resources and captures example entry state.
    function lifecycle.example_entry()
        active_example = nil
        reset('before example')
        assert(active_suite ~= nil,
            'focus lifecycle has no active file suite')
        active_example = {attribution='before_each',
            suite=active_suite.identity:copy(), before=guard:capture()}
    end

    ---Attributes the current example to its Busted identity.
    ---@param identity table
    function lifecycle.test_start(identity)
        if active_example == nil then return end
        active_example.attribution = 'test'
        active_example.example_name = identity.example_name
        active_example.source_identity = identity.source_identity
    end

    ---Resets example resources and publishes its focus comparison.
    function lifecycle.example_exit()
        local completed = active_example
        active_example = nil
        reset('after example')
        if completed == nil then return end
        publish(guard:compare(completed.before, guard:capture()),
            'example', completed.attribution, completed.suite, completed)
    end

    ---Clears unconsumed lifecycle observations.
    function lifecycle.clear()
        active_example, active_suite = nil, nil
    end
    return lifecycle
end

---Installs lifecycle entry after framework setup and before project setup.
---@param adapter table
---@param busted table
---@param lifecycle table
function M.install_entry(adapter, busted, lifecycle)
    assert(type(adapter) == 'table' and
        type(adapter.install_example_entry) == 'function',
        'Busted lifecycle adapter is required')
    adapter.install_example_entry(busted, lifecycle.example_entry)
end

---Installs lifecycle exit after project teardown.
---@param adapter table
---@param busted table
---@param lifecycle table
function M.install_exit(adapter, busted, lifecycle)
    assert(type(adapter) == 'table' and
        type(adapter.install_example_exit) == 'function',
        'Busted lifecycle adapter is required')
    adapter.install_example_exit(busted, lifecycle.example_exit)
end

return M
