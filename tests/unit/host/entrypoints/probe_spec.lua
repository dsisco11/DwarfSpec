-- Unit contracts for the dependency-free DFHack connection probe.

local layout = require('dwarfspec.layout')

---Loads the direct probe entrypoint through the package layout authority.
---@return function
local function load_probe()
    return assert(loadfile(layout.current().host_scripts.probe))
end

---Returns the number of currently loaded Lua modules.
---@return integer
local function loaded_module_count()
    local count = 0
    for _ in pairs(package.loaded) do count = count + 1 end
    return count
end

describe('DFHack connection probe entrypoint', function()
    local original_dfhack
    local original_print
    local original_require
    local original_reqscript
    local lines

    before_each(function()
        original_dfhack = rawget(_G, 'dfhack')
        original_print = rawget(_G, 'print')
        original_require = rawget(_G, 'require')
        original_reqscript = rawget(_G, 'reqscript')
        lines = {}
        rawset(_G, 'print', function(line)
            table.insert(lines, line)
        end)
    end)

    after_each(function()
        rawset(_G, 'dfhack', original_dfhack)
        rawset(_G, 'print', original_print)
        rawset(_G, 'require', original_require)
        rawset(_G, 'reqscript', original_reqscript)
    end)

    ---Executes the probe with one modeled DFHack global.
    ---@param context any
    ---@return string
    local function probe(context)
        rawset(_G, 'dfhack', context)
        assert.has_no.errors(load_probe())
        assert.equals(1, #lines)
        assert.matches('^DWARFSPEC_PROBE ', lines[1])
        return lines[1]
    end

    it('reports the exact healthy protocol 2 response', function()
        local line = probe({
            VERSION='53.15-r1',
            is_core_context=true,
            timeout=function() end,
        })

        assert.equals('DWARFSPEC_PROBE protocol=2 core=true ' ..
            'timeout=function dfhack=53.15-r1', line)
    end)

    it('reports an absent DFHack global without throwing', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=unavailable ' ..
            'timeout=unavailable', probe(nil))
    end)

    it('reports a missing core-context capability independently', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=unavailable ' ..
            'timeout=function', probe({timeout=function() end}))
    end)

    it('reports a missing timeout capability independently', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=true timeout=nil',
            probe({is_core_context=true}))
    end)

    it('normalizes an incorrectly typed core-context capability', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=unavailable ' ..
            'timeout=function', probe({
                is_core_context='true',
                timeout=function() end,
            }))
    end)

    it('reports an incorrectly typed timeout capability', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=true timeout=table',
            probe({is_core_context=true, timeout={}}))
    end)

    it('omits an unsafe optional DFHack version', function()
        assert.equals('DWARFSPEC_PROBE protocol=2 core=true ' ..
            'timeout=function', probe({
                VERSION='53.15 release candidate',
                is_core_context=true,
                timeout=function() end,
            }))
    end)

    it('does not load project or third-party modules', function()
        rawset(_G, 'dfhack', {
            is_core_context=true,
            timeout=function() end,
        })
        local chunk = load_probe()
        rawset(_G, 'require', function()
            error('probe must not call require')
        end)
        rawset(_G, 'reqscript', function()
            error('probe must not call reqscript')
        end)
        local loaded_before = loaded_module_count()

        local ok, probe_error = pcall(chunk)
        local loaded_after = loaded_module_count()
        rawset(_G, 'require', original_require)
        rawset(_G, 'reqscript', original_reqscript)

        assert.is_true(ok, probe_error)
        assert.equals(loaded_before, loaded_after)
        assert.same({'DWARFSPEC_PROBE protocol=2 core=true ' ..
            'timeout=function'}, lines)
    end)
end)
