-- Verifies that the external command reached DFHack's core Lua context.

print(('DWARFSPEC_PROBE protocol=1 core=%s timeout=%s')
    :format(tostring(dfhack.is_core_context), type(dfhack.timeout)))
