-- Third multi-project fixture with the same canonical identity as its peers.

local marker = require('tests.support.project_marker')

describe('service project gamma', function()
    it('retains gamma ownership while holding the executor', function()
        assert.equals('gamma', marker.identity)
        assert.equals('gamma', ds.project_identity())
        assert.is_nil(package.path:match('service_project_alpha'))
        assert.is_nil(package.path:match('service project beta'))
        local run = ds.current_run()
        local mount = assert(run.mount_cleanup_probe())
        assert.is_nil(mount.current_mount_id)
        assert.equals(0, mount.active_screen_count)
        assert.equals(0, mount.subject_count)
        assert.is_false(mount.pointer_active)
        local polls = 0
        ds.await('gamma FIFO hold', function()
            polls = polls + 1
            return polls >= 60
        end)
    end)
end)
