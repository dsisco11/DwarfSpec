# Consumer configuration

Consumer configuration is optional. DwarfSpec loads Lua files directly under
`tests/dwarfspec/` in deterministic order: `config.lua` first, then every other
`*.lua` file alphabetically.

`config.lua` may return global wait defaults:

```lua
return {
    settings={
        wait={frame_budget=300, timeout_ms=10000},
    },
}
```

Both values are optional positive integers. Other modules cannot define
settings.

Any module in this directory may declare custom commands and diagnostic
adapters:

```lua
return {
    commands={
        selected_text=function(ds, view)
            return ds.inspect(view).text
        end,
    },
    diagnostics={
        tooltip=function(ds, service)
            return service:get_diagnostics()
        end,
    },
}
```

Commands become `ds.selected_text(...)`. Diagnostic adapters are invoked as
`ds.diagnostic('tooltip', ...)`. The first callback argument is always the
isolated run-scoped `ds` object. Names must be Lua identifiers, duplicate names
are rejected, and commands cannot replace built-in `ds` methods.

Modules execute in isolated environments. They can read normal Lua and DFHack
globals, but assigning a global does not modify the process-wide `_G` table.
