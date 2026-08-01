-- Production adapter that verifies access to DFHack's core Lua context.

print(('DWARFSPEC_PROBE protocol=2 core=%s timeout=%s')
    :format(tostring(dfhack.is_core_context), type(dfhack.timeout)))
