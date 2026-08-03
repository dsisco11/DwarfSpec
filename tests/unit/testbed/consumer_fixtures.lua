-- Consumer-shaped in-memory Lua sources shared by TestBed unit suites.

local M = {}

---Conventional module sources for native cache and cycle semantics.
---@type table<string, string>
M.CONVENTIONAL = {
    ['modules/nil_result.lua']='counter.nil_calls = counter.nil_calls + 1; return nil',
    ['modules/false_result.lua']='counter.calls = counter.calls + 1; return false',
    ['modules/published_nil.lua']=[[
        package.loaded.published_nil = {kind='published'}
        return nil
    ]],
    ['modules/returned_override.lua']=[[
        package.loaded.returned_override = {kind='published'}
        return {kind='returned'}
    ]],
    ['modules/published/a.lua']=[[
        local module = mkmodule('published.a')
        module.started = true
        module.b = require('published.b')
        module.finished = true
        return module
    ]],
    ['modules/published/b.lua']=[[
        local a = require('published.a')
        return {a=a, saw_started=a.started, saw_finished=a.finished}
    ]],
    ['modules/retry.lua']='error("first source failure")',
}

return M
