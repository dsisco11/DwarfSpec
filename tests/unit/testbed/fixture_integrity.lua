-- Integrity guard for the checked-in TestBed consumer fixture tree.

local lfs = require('lfs')

local FIXTURE_ROOT = 'tests/fixtures/testbed/consumer'

---Captures process state and checked-in fixture contents for later verification.
---@class tests.TestBedFixtureIntegrityGuard
---@field private assertions table
---@field private process_state table<string, any>
---@field private fixture_state table<string, string|boolean>
local FixtureIntegrityGuard = {}
FixtureIntegrityGuard.__index = FixtureIntegrityGuard

---Reads the complete relative-file map beneath a fixture directory.
---@param root string
---@param relative? string
---@param snapshot? table<string, string|boolean>
---@return table<string, string|boolean>
local function snapshot_tree(root, relative, snapshot)
    relative, snapshot = relative or '', snapshot or {}
    local directory = relative == '' and root or root .. '/' .. relative
    for entry in lfs.dir(directory) do
        if entry ~= '.' and entry ~= '..' then
            local child = relative == '' and entry or relative .. '/' .. entry
            local path = root .. '/' .. child
            if lfs.attributes(path, 'mode') == 'directory' then
                snapshot[child .. '/'] = true
                snapshot_tree(root, child, snapshot)
            else
                local file = assert(io.open(path, 'rb'))
                snapshot[child] = assert(file:read('*a'))
                file:close()
            end
        end
    end
    return snapshot
end

---Constructs an integrity guard from the current process and fixture state.
---@param assertions table Busted assertion object owned by the calling spec
---@return tests.TestBedFixtureIntegrityGuard
function FixtureIntegrityGuard.new(assertions)
    return setmetatable({
        assertions=assertions,
        process_state={
            open=io.open,
            popen=io.popen,
            rename=os.rename,
            loadfile=loadfile,
            directory=lfs.currentdir(),
        },
        fixture_state=snapshot_tree(FIXTURE_ROOT),
    }, FixtureIntegrityGuard)
end

---Asserts that process globals, working directory, and fixtures are unchanged.
function FixtureIntegrityGuard:assert_unchanged()
    self.assertions.equals(self.process_state.open, io.open)
    self.assertions.equals(self.process_state.popen, io.popen)
    self.assertions.equals(self.process_state.rename, os.rename)
    self.assertions.equals(self.process_state.loadfile, loadfile)
    self.assertions.equals(self.process_state.directory, lfs.currentdir())
    self.assertions.same(self.fixture_state, snapshot_tree(FIXTURE_ROOT))
end

return {
    FIXTURE_ROOT=FIXTURE_ROOT,
    FixtureIntegrityGuard=FixtureIntegrityGuard,
}
