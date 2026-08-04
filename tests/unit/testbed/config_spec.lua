-- Unit contracts for TestBed configuration normalization.

local config = require('dwarfspec.testbed.config')

---Returns one minimal provider for the requested token and strategy.
---@param kind string
---@param name string
---@param strategy string
---@param value any
---@return table
local function provider(kind, name, strategy, value)
    return {provide={kind=kind, name=name}, [strategy]=value}
end

---Asserts that normalization fails with an actionable configuration path.
---@param value any
---@param expected string
local function assert_invalid(value, expected)
    local ok, message = pcall(config.normalize, value)
    assert.is_false(ok)
    assert.is_not_nil(message:find(expected, 1, true))
end

describe('TestBed configuration normalization', function()
    it('applies standalone defaults and records skipped default roots', function()
        local normalized = config.normalize(nil, {
            consumer_root='consumer',
            directory_exists=function(path)
                return not path:find('scripts_modinstalled', 1, true)
            end,
        })

        assert.equals('src', normalized.module_roots[1])
        assert.equals('.', normalized.module_roots[2])
        assert.equals(2, #normalized.module_roots)
        assert.equals(0, #normalized.script_roots)
        assert.equals('src/scripts_modinstalled',
            normalized.attempted_module_roots[1])
        assert.equals('src', normalized.attempted_module_roots[2])
        assert.equals('.', normalized.attempted_module_roots[3])
        assert.is_false(normalized.component_imports)
        assert.equals(0, #normalized.imports)
    end)

    it('validates all top-level configuration shapes', function()
        assert_invalid(false, 'config')
        assert_invalid({unknown=true}, 'config.unknown')
        assert_invalid({module_roots={'src', 3}}, 'config.module_roots[2]')
        assert_invalid({module_roots={[1]='src', [3]='.'}}, 'config.module_roots')
        assert_invalid({globals={[1]='bad'}}, 'globals')
        assert_invalid({globals={dfhack=false}}, 'globals.dfhack')
        assert_invalid({globals={require=function() end}}, 'globals.require')
        assert_invalid({component_imports='yes'}, 'config.component_imports')
    end)

    it('accepts every optional top-level field independently', function()
        local cases = {
            {},
            {module_roots={'modules'}},
            {script_roots={'scripts'}},
            {globals={custom=true}},
            {component_imports=false},
            {imports={provider('module', 'value', 'use_value', true)}},
        }
        for _, value in ipairs(cases) do
            local normalized = config.normalize(value, {
                directory_exists=function() return true end,
            })
            assert.is_table(normalized)
        end
    end)

    it('uses explicit roots as replacements, including empty arrays', function()
        local normalized = config.normalize({module_roots={}, script_roots={'custom'}}, {
            directory_exists=function() return false end,
        })

        assert.equals(0, #normalized.module_roots)
        assert.equals('custom', normalized.script_roots[1])
        assert.equals(0, #normalized.attempted_module_roots)
        assert.equals('custom', normalized.attempted_script_roots[1])
    end)

    it('validates provider tokens and exact strategies', function()
        assert_invalid({imports=false}, 'config.imports')
        assert_invalid({imports={{provide={kind='other', name='x'}, use_value=true}}},
            'config.imports[1].provide.kind')
        assert_invalid({imports={{provide={kind='module', name=1}, use_value=true}}},
            'config.imports[1].provide.name')
        assert_invalid({imports={{provide={kind='module', name='x'}, use_value=true,
            use_source='x.lua'}}}, 'config.imports[1]')
        assert_invalid({imports={{provide={kind='module', name='x'}}}},
            'config.imports[1]')
        assert_invalid({imports={{provide={kind='module', name='x'},
            use_source=false}}}, 'config.imports[1].use_source')
        assert_invalid({imports={{provide={kind='module', name='x'},
            use_existing='x'}}}, 'config.imports[1].use_existing')
        assert_invalid({imports={{provide={kind='module', name='x'},
            use_value=true, unexpected=true}}}, 'config.imports[1].unexpected')
        assert_invalid({imports={{provide={kind='module', name='x'}, use_host=false}}},
            'config.imports[1].use_host')
        assert_invalid({imports={{provide={kind='script', name='x'}, use_value=false}}},
            'config.imports[1].use_value')
        assert_invalid({imports={{provide={kind='module', name='dfhack'}, use_value=true}}},
            'config.imports[1].provide')
        assert_invalid({imports={provider('module', 'duplicate', 'use_value', true),
            provider('module', 'duplicate', 'use_value', false)}},
            'config.imports[2].provide')
        assert_invalid({imports={{provide={kind='module', name='x'},
            use_existing={kind='script', name='x'}}}},
            'config.imports[1].use_existing.kind')
    end)

    it('accepts and rejects the complete provider shape matrix', function()
        local shapes = {
            {name='provider-use-value-valid', valid=true,
                config={imports={provider('module', 'value', 'use_value', true)}}},
            {name='provider-use-source-valid', valid=true,
                config={imports={provider('script', 'source', 'use_source', 'source.lua')}}},
            {name='provider-use-host-valid', valid=true,
                config={imports={provider('module', 'host', 'use_host', true)}},
                options={profile='mount', host_importer=function() end}},
            {name='provider-use-existing-valid', valid=true,
                config={imports={provider('script', 'alias', 'use_existing',
                    {kind='script', name='source'})}}},
            {name='provider-missing-token-invalid', valid=false,
                config={imports={{provide={kind='module'}, use_value=true}}}},
            {name='provider-nil-strategy-invalid', valid=false,
                config={imports={{provide={kind='module', name='nil'}, use_value=nil}}}},
            {name='provider-cross-namespace-invalid', valid=false,
                config={imports={{provide={kind='module', name='value'},
                    use_existing={kind='script', name='value'}}}}},
            {name='provider-multiple-strategies-invalid', valid=false,
                config={imports={{provide={kind='module', name='value'},
                    use_value=true, use_host=true}}}},
            {name='provider-unknown-strategy-invalid', valid=false,
                config={imports={{provide={kind='module', name='value'},
                    use_unknown=true}}}},
        }
        for _, shape in ipairs(shapes) do
            local ok = pcall(config.normalize, shape.config, shape.options)
            assert.equals(shape.valid, ok, shape.name)
        end
    end)

    it('reports every remaining collection, token, and reserved-global shape',
            function()
        local invalid_cases = {
            {{script_roots='scripts'}, 'config.script_roots'},
            {{script_roots={[1]='scripts', [3]='other'}}, 'config.script_roots'},
            {{script_roots={'scripts', false}}, 'config.script_roots[2]'},
            {{imports={[1]=provider('module', 'x', 'use_value', true), [3]=
                provider('module', 'y', 'use_value', true)}}, 'config.imports'},
            {{imports={'not-a-provider'}}, 'config.imports[1]'},
            {{imports={{provide=false, use_value=true}}},
                'config.imports[1].provide'},
            {{imports={{provide={kind='module', name='x', extra=true},
                use_value=true}}}, 'config.imports[1].provide.extra'},
            {{imports={{provide={name='x'}, use_value=true}}},
                'config.imports[1].provide.kind'},
            {{imports={{provide={kind='module'}, use_value=true}}},
                'config.imports[1].provide.name'},
            {{imports={{provide={kind='module', name='x'}, use_existing={
                kind='module', name=false}}}},
                'config.imports[1].use_existing.name'},
        }
        for _, case in ipairs(invalid_cases) do assert_invalid(case[1], case[2]) end

        local reserved = {
            '_G', 'require', 'reqscript', 'mkmodule', 'package', 'load',
            'loadfile', 'dofile', 'reload', 'script_environment',
            'dfhack_flags',
        }
        for _, name in ipairs(reserved) do
            assert_invalid({globals={[name]=true}}, 'globals.' .. name)
        end
    end)

    it('preserves valid empty names, false module values, and namespace identity', function()
        local normalized = config.normalize({imports={
            provider('module', '', 'use_value', false),
            provider('script', '', 'use_value', {}),
            provider('module', 'empty-path', 'use_source', ''),
            provider('module', 'alias', 'use_existing',
                {kind='module', name='empty-path'}),
        }})

        assert.equals(false, normalized.provider_registry.module[''].use_value)
        assert.is_table(normalized.provider_registry.script[''].use_value)
        assert.equals('', normalized.provider_registry.module['empty-path'].use_source)
        assert.equals('empty-path',
            normalized.provider_registry.module.alias.use_existing.name)
        assert.equals(4, #normalized.imports)
    end)

    it('rejects host imports without a live importer and supports private mount inputs', function()
        assert_invalid({imports={provider('module', 'host', 'use_host', true)}},
            'config.imports[1].use_host')
        assert_invalid({component_imports=true}, 'config.component_imports')

        local normalized = config.normalize({imports={
            provider('module', 'class', 'use_value', {replacement=true}),
        }}, {
            profile='mount', host_importer=function() end,
            synthesized_providers={provider('module', 'class', 'use_host', true),
                provider('module', 'gui', 'use_host', true)},
        })

        assert.is_true(normalized.component_imports)
        assert.is_true(normalized.provider_registry.module.class.use_value.replacement)
        assert.is_true(normalized.provider_registry.module.gui.use_host)
        assert.equals(2, #normalized.imports)
        assert.equals('gui', normalized.imports[1].provide.name)
        assert.equals('class', normalized.imports[2].provide.name)

        local disabled = config.normalize({component_imports=false}, {
            profile='mount', host_importer=function() end,
            synthesized_providers={provider('module', 'gui', 'use_host', true)},
        })
        assert.equals(0, #disabled.imports)
    end)

    it('freezes copied containers while retaining borrowed payload identities', function()
        local payload = {value=1}
        local global_value = {value=2}
        local input = {module_roots={'first'}, globals={custom=global_value}, imports={
            provider('module', 'value', 'use_value', payload),
        }}
        local normalized = config.normalize(input, {
            directory_exists=function() return true end,
        })
        input.module_roots[1] = 'changed'
        input.imports[1].provide.name = 'changed'
        input.imports[2] = provider('module', 'later', 'use_value', true)
        input.globals.custom = {replacement=true}
        payload.value = 3
        global_value.value = 4

        assert.equals('first', normalized.module_roots[1])
        assert.is_not_nil(normalized.provider_registry.module.value)
        assert.equals(3, normalized.provider_registry.module.value.use_value.value)
        assert.equals(4, normalized.globals.custom.value)
        assert.equals(1, #normalized.imports)
        assert.is_nil(normalized.provider_registry.module.later)
        assert.is_nil(normalized.package)
        local roots_ok, roots_message = pcall(function()
            normalized.module_roots[1] = 'changed'
        end)
        local token_ok, token_message = pcall(function()
            normalized.provider_registry.module.value.provide.name = 'changed'
        end)
        assert.is_false(roots_ok)
        assert.is_false(token_ok)
        assert.matches('immutable', roots_message)
        assert.matches('immutable', token_message)
    end)
end)
