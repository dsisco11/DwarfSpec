-- Multi-project fixture with an identity intentionally shared by another root.

local marker = require('tests.support.project_marker')

describe('service project alpha', function()
    it('retains alpha ownership while holding the executor', function()
        assert.equals('alpha', marker.identity)
        assert.equals('alpha', ds.project_identity())
        assert.is_nil(package.path:match('service project beta'))
        assert.is_nil(package.path:match('service_project_gamma'))
        local polls = 0
        ds.await('alpha FIFO hold', function()
            polls = polls + 1
            return polls >= 300
        end)
    end)
end)
