-- Project-specific command used by multi-project isolation evidence.

---Returns the owning fixture-project identity.
---@return string
local function project_identity()
    return 'beta'
end

return {
    commands={
        project_identity=project_identity,
    },
}
