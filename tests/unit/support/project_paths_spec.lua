local project_paths = require('dwarfspec.support.project_paths')

describe('support project paths', function()
    it('joins relative paths using the active platform separator', function()
        local separator = package.config:sub(1, 1)
        assert.are.equal('root' .. separator .. 'child' .. separator .. 'file',
            project_paths.join('root', 'child/file'))
    end)

    it('recognizes Windows and Unix absolute paths', function()
        assert.is_true(project_paths.is_absolute('C:/project'))
        assert.is_true(project_paths.is_absolute('/project'))
        assert.is_false(project_paths.is_absolute('project/tests'))
    end)

    it('normalizes separators, current-directory segments, and trailing slashes', function()
        assert.are.equal('project/tests/spec.lua',
            project_paths.normalize('project\\./tests/spec.lua/'))
    end)
end)
