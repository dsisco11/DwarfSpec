-- Shared configuration and evidence for TestBed descriptor live proofs.

local MODULE_ROOT = 'tests/fixtures/testbed/live_consumer/src'
local SCRIPT_ROOT = MODULE_ROOT .. '/scripts_modinstalled'

---Owns provider values and mount helpers for one live proof.
---@class tests.TestBedLiveFixture
---@field assertions table
---@field module_value table
---@field script_value table
---@field probe table
---@field observer table
local TestBedLiveFixture = {}
TestBedLiveFixture.__index = TestBedLiveFixture

---Normalizes one source filename for stable path comparison.
---@param value string
---@return string
local function normalize_source(value)
    return value:gsub('^@', ''):gsub('\\', '/'):lower()
end

---Returns the source file that defines one callable value.
---@param value function
---@return string
local function callable_source(value)
    local info = assert(debug.getinfo(value, 'S'))
    return normalize_source(assert(info.source))
end

---Constructs isolated provider values for one automation example.
---@param assertions table Busted assertion object owned by the calling spec
---@param observer? table Borrowed interaction observer supplied by the spec
---@return tests.TestBedLiveFixture
function TestBedLiveFixture.new(assertions, observer)
    return setmetatable({
        assertions=assertions,
        module_value={text='module replacement'},
        script_value={text='script replacement'},
        probe={},
        observer=observer or {record=function() end},
    }, TestBedLiveFixture)
end

---Builds one fresh TestBed configuration over the read-only consumer tree.
---@return dwarfspec.TestBedConfig
function TestBedLiveFixture:config()
    return {
        module_roots={MODULE_ROOT},
        script_roots={SCRIPT_ROOT},
        imports={
            {provide={kind='module', name='testbed_live.module_value'},
                use_value=self.module_value},
            {provide={kind='script', name='testbed_live.script_value'},
                use_value=self.script_value},
            {provide={kind='module', name='testbed_live.probe'},
                use_value=self.probe},
            {provide={kind='module', name='testbed_live.observer'},
                use_value=self.observer},
        },
    }
end

---Mounts one exported consumer component through a module descriptor.
---@param ds table
---@param export string
---@return dwarfspec.Subject
function TestBedLiveFixture:mount(ds, export)
    return ds.mount({
        kind='module',
        name='testbed_live.component',
        export=export,
    }, {
        viewport={width=50, height=12},
    }, self:config())
end

---Returns the resolved active-source paths recorded by live test names.
---@param ds table
---@return table
function TestBedLiveFixture.source_evidence(ds)
    local run = ds.current_run()
    local root = normalize_source(assert(run.package_root))
    local TestBed = require('dwarfspec.testbed')
    local internal = require('dwarfspec.testbed.internal')
    return {
        public=callable_source(TestBed.new),
        internal=callable_source(internal.new),
        expected_public=root .. '/dwarfspec/testbed.lua',
        expected_internal=root .. '/dwarfspec/testbed/internal.lua',
    }
end

---Proves public and internal TestBed code came from the active repository.
---@param ds table
function TestBedLiveFixture:assert_active_source(ds)
    local evidence = TestBedLiveFixture.source_evidence(ds)
    self.assertions.equals(evidence.expected_public, evidence.public)
    self.assertions.equals(evidence.expected_internal, evidence.internal)
end

---Asserts that the active run owns no remaining mount resources.
---@param ds table
function TestBedLiveFixture:assert_clean(ds)
    local cleanup = ds.current_run().mount_cleanup_probe()
    self.assertions.is_nil(cleanup.current_mount_id)
    self.assertions.equals(0, cleanup.active_screen_count)
    self.assertions.equals(0, cleanup.owned_screen_count)
    self.assertions.equals(0, cleanup.subject_count)
end

return {
    TestBedLiveFixture=TestBedLiveFixture,
}
