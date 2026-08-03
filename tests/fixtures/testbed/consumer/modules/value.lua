local script = reqscript('worker')

---Returns a value that remains usable after its owning TestBed closes.
---@return string
local function keep()
    return 'kept'
end

---Defers a module lookup so lifecycle guards can be tested after close.
---@return any
local function deferred()
    return require('other')
end

return {
    value=script.value,
    keep=keep,
    deferred=deferred,
}
