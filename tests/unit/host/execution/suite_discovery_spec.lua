local module = require('dwarfspec.host.execution.suite_discovery')

describe('host suite discovery', function()
    it('validates paths and enables recursive Busted loading', function()
        local call
        local discovery = module.new(function(root, path)
            return root .. '/' .. path
        end)
        local result = discovery.discover('project', function(roots, patterns, options)
            call = {roots=roots, patterns=patterns, options=options}
            return {'loaded'}
        end, {'a_spec.lua'})
        assert.same({'loaded'}, result)
        assert.same({'project/tests/a_spec.lua'}, call.roots)
        assert.is_true(call.options.recursive)
        assert.has_error(function()
            discovery.discover('project', function() end, {'../bad.lua'})
        end)
        assert.has_error(function()
            discovery.discover('project', function() end, {'/bad.lua'})
        end)
        assert.has_error(function()
            discovery.discover('project', function() end, {'C:\\bad.lua'})
        end)
    end)

    it('constructs every supported Busted filter option', function()
        local options = module.new(function() end).filter_options({
            tags='fast', exclude_tags={'slow'}, filters='name',
            names='example', filter_out='skip'})
        assert.same({'fast'}, options.tags)
        assert.same({'slow'}, options.excludeTags)
        assert.same({'name'}, options.filter)
        assert.same({'example'}, options.name)
        assert.same({'skip'}, options.filterOut)
        assert.is_nil(options.excludeNamesFile)
        assert.is_false(options.list)
        assert.is_false(options.nokeepgoing)
        assert.is_false(options.suppressPending)
    end)
end)
