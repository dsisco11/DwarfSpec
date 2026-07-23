-- Space-containing multi-project fixture with a deliberately shared identity.

local marker = require('tests.support.project_marker')

describe('service project beta', function()
    it('retains beta ownership while holding the executor', function()
        assert.equals('beta', marker.identity)
        assert.equals('beta', ds.project_identity())
        assert.is_nil(package.path:match('service_project_alpha'))
        assert.is_nil(package.path:match('service_project_gamma'))
        local polls = 0
        ds.await('beta FIFO hold', function()
            polls = polls + 1
            return polls >= 180
        end)
    end)
end)
