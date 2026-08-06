-- Static declaration coverage for verified command execution contracts.

---@type dwarfspec.CommandOptions
local command_options = {
    timeout_ms=250,
    description='read the current clock',
    verify=function(observation)
        return observation.name == 'getTime'
    end,
}

---@type dwarfspec.CommandDefinition
local definition = {
    name='syntheticQuery',
    kind='query',
    normalize=function(arguments) return arguments end,
    preflight=function(_, request)
        return {kind='ready', value=request}
    end,
    execute=function(_, _, ready)
        return {kind='executed', receipt=ready}
    end,
    execution_retry_policy='once',
    intrinsic_verification='execution_receipt',
    verify=function(_, _, receipt)
        return {kind='ready', evidence={receipt=receipt}}
    end,
}

---@type dwarfspec.CleanupRegistration
local cleanup = {
    label='remove synthetic item',
    receipt={item_id=42},
    restore=function(_, receipt) assert(receipt.item_id == 42) end,
    verify=function(_, receipt) return receipt.item_id == 42 end,
    cleanup_timeout_ms=250,
    resources={{
        claim_key='item', resource_kind='synthetic_item',
        resource_identity='42', exclusive=true,
    }},
}

local now = ds.getTime(command_options)
local root = ds.root(nil, command_options)
root:inspect(command_options)
root:click('left', command_options)
ds.search({text='example'}, root, command_options)

-- These declarations are consumed by future registry bindings.
local _ = {definition=definition, cleanup=cleanup, now=now}
