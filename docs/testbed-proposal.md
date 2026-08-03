# DwarfSpec TestBed evaluation

## Executive assessment

A DwarfSpec `TestBed` would be useful and is worth prototyping.

The strongest use case is not general-purpose dependency injection. It is an
instance-scoped Lua module graph that:

- loads consumer source through a TestBed-owned `require`;
- gives each bed its own module cache and module environments;
- allows exact module replacements without modifying global `package.loaded`;
- supports DFHack's `mkmodule` convention;
- can run in either standalone Lua or the embedded DFHack interpreter; and
- participates in DwarfSpec cleanup when used by a live test.

This would remove repeated `package.loaded` and `_G` manipulation from
standalone tests, give live component tests fresh consumer module state per
example, and make dependency replacement explicit.

The system must not claim to be a complete Lua VM sandbox. A fresh module graph
does not undo writes to borrowed tables, native DF state, event registries,
files, timers, screens, or plugin state. DwarfSpec's existing resource cleanup
remains responsible for owned live resources, and process isolation remains the
only strong boundary for arbitrary code.

Recommendation: proceed with a small loader-centered TestBed. Do not build a
general-purpose injection container, a second test framework, or an automatic
mocking system.

## The problem in the current system

DwarfSpec already provides useful run-level module hygiene for live tests:

- the consumer project root is inserted into `package.path`;
- DwarfSpec and Busted paths retain priority;
- modules newly loaded from the consumer root are evicted at run cleanup; and
- the exact prior `package.path` is restored.

That protects consecutive live runs from many stale consumer modules, but it
does not provide a private module graph for one example:

- every test still uses the process-global `require` cache;
- a module loaded at spec-file scope is shared by every example in that file;
- a module already cached before the run is not made fresh;
- dependency replacement requires global `package.loaded` changes;
- module global writes can persist for the life of the cached module;
- standalone unit tests need their own stubbing and cleanup conventions; and
- the current run cleanup cannot distinguish two independently configured
  versions of the same module within one Lua process.

The private environment used for DwarfSpec configuration extensions solves a
narrower problem. It isolates direct global assignments while loading one file,
but it delegates nested `require` calls to the process-global loader and does
not own a dependency graph.

The proposed TestBed should complement the existing run-level path boundary.
It should be opt-in and should not replace the host's loader, Busted, spec
discovery, or normal `require` behavior for existing tests.

## Design principles

The TestBed should provide a test-local composition root, controlled dependency
replacement, module retrieval, and deterministic close behavior.

Its core principles should be:

- make the conventional case work with `TestBed.new()` and with a tagged
  component-source descriptor passed to `ds.mount`;
- declare the environment before loading the subject;
- prefer real dependencies unless a test explicitly replaces one;
- use fixed, documented defaults rather than scanning for a plausible layout;
- freeze configuration at TestBed construction;
- create fresh state for each example; and
- make teardown deterministic.

Ordinary Lua modules obtain dependencies through `require`, globals, and
captured values. A static TestBed API would add another global mutable registry
on top of `package.loaded`, which is the state the feature is intended to
avoid.

DwarfSpec should therefore expose ordinary TestBed instances to standalone
callers. A TestBed-backed component mount accepts a tagged logical module or
script descriptor and the same declarative configuration type through one
optional final parameter. Such a mount always creates a mount-owned TestBed;
omitting the configuration means the fixed defaults. An ordinary component
class mount preserves the existing TestBed-free path and does not accept
TestBed configuration. `ds.mount` no longer accepts an already-created
component instance, since its construction and captured dependencies occurred
outside the mount's ownership boundary. The mount command never accepts an
instantiated TestBed.

## Recommended public contract

The framework-neutral zero-configuration path should be:

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new()
local controller = bed:require('my_plugin.controller')
```

Live component tests should pass that configuration directly to `ds.mount`:

```lua
---@type dwarfspec.TestBedConfig
local testbed = {
    imports={
        {
            provide={kind='module', name='my_plugin.storage'},
            use_value=fake_storage,
        },
    },
}

ds.mount({
    kind='module',
    name='my_plugin.save_panel',
    export='SavePanel',
}, {
    title='Saved value',
}, testbed)
```

`TestBed.new()` must accept a missing configuration table, and every TestBed
configuration field must be optional. Configuration is progressive: users
should provide only values that differ from the defaults. For example, a unit
test replacing one dependency should need only:

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new{
    imports={
        {
            provide={kind='module', name='my_plugin.clock'},
            use_value=fake_clock,
        },
    },
}

local controller = bed:require('my_plugin.controller')
```

All configuration fields should be optional:

| Field | Default | Customization |
|---|---|---|
| `module_roots` | `src/scripts_modinstalled`, then `src`, then `.` relative to the project root. | Replacement ordered roots used to construct the initial private `package.path`. |
| `globals` | The explicit standard-Lua binding set plus a minimal bed-local `dfhack` facade offline; that set plus a construction-time snapshot of non-reserved `dfhack.BASE_G` bindings live. | Additional globals and replacements for non-reserved runtime globals. `globals.dfhack` is the sole mock backing input for ordinary DFHack APIs. |
| `component_imports` | `false` offline; `true` for a TestBed-backed `ds.mount`. | Enables or disables the documented foundational host-module set. |
| `imports` | Empty. | Ordered `TestBedImport` providers for exact module or script tokens. |
| `script_roots` | `src/scripts_modinstalled` relative to the project root. | Replacement ordered roots searched by bed-local `reqscript`. |

### Authoring-time type contract

The configuration must be one canonical public type named
`dwarfspec.TestBedConfig`. It must be defined by the active source repository
and visible to Lua language servers when a consumer loads
`dwarfspec.testbed` or uses `src/ds.d.lua`.

The provider key is the pair `(kind, name)`. Modules and scripts therefore
remain separate namespaces even when their names are identical. Each provider
must specify exactly one strategy:

- `use_value` returns the exact borrowed non-`nil` value. `false` is valid for a
  module and follows Lua's normal reload semantics; a script value must be a
  table;
- `use_source` loads the exact file inside the bed;
- `use_host` borrows the exact result of host `require` or `reqscript`. It is
  available only from the live adapter and is an explicit escape from graph
  freshness and ownership. Invoking the host loader may also populate or reuse
  its process-global module or script cache; and
- `use_existing` aliases another token in the same namespace and returns the
  exact same identity.

The initial contract intentionally omits factories, classes, dependency lists,
and multi-providers. Duplicate user-provided tokens, multiple strategies on one
provider, cross-namespace aliases, and unknown fields are errors. Strategy
selection is based on raw field presence rather than truthiness, so
`use_value=false` is recognized while `use_value=nil` is rejected as an absent
strategy. The configuration validator copies the provider array, provider
tables, tokens, roots, and globals container; a `use_value` payload is
deliberately borrowed.

The module token `{kind='module', name='dfhack'}` is reserved and cannot appear
as a provider's `provide` token with any strategy. DFHack is simultaneously a
global API namespace and a requireable module, so allowing an ordinary provider
would create two competing configuration sources. Tests mock its ordinary API
members through `globals.dfhack`; TestBed owns the facade placed over that
backing table.

For example, a standalone test can replace the ordinary timeout API without
constructing or modifying loader operations:

```lua
local bed = TestBed.new{
    globals={
        dfhack={
            timeout=function(_, _, callback) callback() end,
        },
    },
}
```

Code loaded by this bed observes that mock through both `dfhack.timeout` and
`require('dfhack').timeout`, while `reqscript`, `BASE_G`, and rejected loader
operations remain owned by TestBed.

The production module should carry the authoritative annotations:

```lua
---@alias dwarfspec.TestBedImportKind
---| '"module"'
---| '"script"'

---Identifies one exact TestBed dependency.
---@class dwarfspec.TestBedImportToken
---@field kind dwarfspec.TestBedImportKind
---@field name string

---Identifies a Lua value that can be present in a provider table.
---@alias dwarfspec.TestBedNonNilValue boolean|number|string|function|table|thread|userdata

---Provides one exact borrowed value.
---@class dwarfspec.TestBedValueImport
---@field provide dwarfspec.TestBedImportToken
---@field use_value dwarfspec.TestBedNonNilValue

---Provides one exact source file loaded by the TestBed.
---@class dwarfspec.TestBedSourceImport
---@field provide dwarfspec.TestBedImportToken
---@field use_source string

---Borrows one exact module or script from the live host.
---@class dwarfspec.TestBedHostImport
---@field provide dwarfspec.TestBedImportToken
---@field use_host true

---Aliases one exact token in the same namespace.
---@class dwarfspec.TestBedExistingImport
---@field provide dwarfspec.TestBedImportToken
---@field use_existing dwarfspec.TestBedImportToken

---@alias dwarfspec.TestBedImport
---| dwarfspec.TestBedValueImport
---| dwarfspec.TestBedSourceImport
---| dwarfspec.TestBedHostImport
---| dwarfspec.TestBedExistingImport

---Provides additional runtime globals and the optional DFHack API backing mock.
---@class dwarfspec.TestBedGlobals: table<string, any>
---@field dfhack? table

---Configures module and script resolution for one TestBed.
---@class dwarfspec.TestBedConfig
---@field module_roots? string[]
---@field globals? dwarfspec.TestBedGlobals
---@field component_imports? boolean
---@field imports? dwarfspec.TestBedImport[]
---@field script_roots? string[]

---Owns one bed-local module and script graph.
---@class dwarfspec.TestBed
local TestBed = {}

---Creates a bed-local module environment from a typed configuration.
---@param config? dwarfspec.TestBedConfig
---@return dwarfspec.TestBed
function TestBed.new(config) end

---Loads one Lua module through this TestBed.
---@param name string
---@return any value
---@return any? loader_data Present only when the running Lua version returns it
---and this call invokes a searcher.
function TestBed:require(name) end

---Loads one annotated DFHack script module through this TestBed.
---@param name string
---@return table
function TestBed:reqscript(name) end

---Closes this TestBed and releases its owned graph.
function TestBed:close() end
```

Every public TestBed method must also be annotated on
`dwarfspec.TestBed`. `ds.d.lua` should reference these canonical types rather
than defining a second, drifting copy:

```lua
---Identifies a callable DFHack defclass table accepted by `ds.mount`.
---Runtime validation distinguishes a class from an already-created instance.
---@alias dwarfspec.ComponentClass table

---Identifies a component exported by a bed-local Lua module.
---@class dwarfspec.ModuleComponentSource
---@field kind '"module"'
---@field name string
---@field export? string

---Identifies a component exported by a bed-local DFHack script module.
---@class dwarfspec.ScriptComponentSource
---@field kind '"script"'
---@field name string
---@field export? string

---Selects a component source that must be resolved through a TestBed.
---@alias dwarfspec.TestBedComponentSource
---| dwarfspec.ModuleComponentSource
---| dwarfspec.ScriptComponentSource
```

The descriptor overload accepts the optional TestBed configuration. The
ordinary class overload remains TestBed-free:

```lua
---Mounts one owned component or complete screen.
---@overload fun(source: dwarfspec.TestBedComponentSource, options?: dwarfspec.MountOptions, testbed?: dwarfspec.TestBedConfig): dwarfspec.Subject
---@param component dwarfspec.ComponentClass
---@param options? dwarfspec.MountOptions
---@return dwarfspec.Subject
function DS.mount(component, options) end
```

Keeping TestBed configuration as the final parameter on the descriptor overload
avoids confusing component constructor options with loader configuration. The
`kind` tag makes module and script descriptors unambiguous, and `name` is a
logical import name rather than a source-file path. Module and script
descriptors always create one fresh mount-owned TestBed, using fixed defaults
when configuration is omitted. Passing a third argument with an already-loaded
class is rejected instead of creating a bed that cannot affect construction.
Already-created component instances are not supported by the revised mount
contract.

This is a strong authoring contract for plain Lua tables, not a new wrapper
builder. Runtime code must apply the same schema: reject unknown fields and
invalid field types, copy mutable configuration containers, normalize paths,
and freeze the normalized initial configuration at construction. Static
annotations and runtime validation must be tested from the active source
repository so the editor contract cannot silently diverge from executable
behavior.

The default roots are a fixed convention, not an open-ended directory scan.
Each module root contributes the ordinary `?.lua` and `?/init.lua` templates to
the initial private `package.path`.
Missing default directories are skipped. An error must list the effective
roots that were tried. Explicitly providing a root list replaces its default,
including with an empty list when a provider-only bed is desired.

The live adapter synthesizes the initial documented component providers as
`TestBedHostImport` entries for only
common, foundational DFHack library modules: `class`, `utils`, `gui`,
`gui.widgets`, and `gui.dwarfmode`. It must not include registry- or
scheduler-oriented modules such as `plugins.overlay`, `plugins.eventful`,
`repeat-util`, or `script-manager`. Tests that need one of those shared host
modules must declare a `use_host` provider in `imports`. The list is enabled by
default for descriptor beds created by `ds.mount` and disabled by default for
standalone beds.
`component_imports=false` disables the synthesized set. A user provider for a
synthesized token replaces that default; duplicate tokens among user entries
remain errors. Since standalone TestBed construction has no live importer,
explicitly enabling `component_imports` there fails validation instead of
creating unusable host providers.

Resolution should be deterministic. The reserved module name `dfhack` is
resolved to the TestBed-owned facade before the ordinary algorithm below and
cannot be redirected through `package.loaded`, `package.preload`, a custom
searcher, or `package.path`. Every other module uses:

1. apply ordinary Lua `package.loaded` cache semantics;
2. search the bed's mutable `package.searchers` in order, whose initial value
   includes `package.preload`, exact import providers, and Lua source search;
3. allow the provider searcher to resolve `use_value`, `use_source`, `use_host`,
   or `use_existing`; or
4. fail with the searcher errors and dependency chain.

The provider searcher precedes source search, so explicit and synthesized
providers reserve exact names against accidental root shadowing. The private
package is authoritative after creation for every non-reserved module name.
Entry mutations in its `loaded` and `preload` tables, replacement or mutation of
`searchers`, and replacement or mutation of `path` affect subsequent bed-local
loads. To match native Lua, assigning a different table to `package.loaded` or
`package.preload` does not replace the internal cache or preload table used by
bed-local `require`; those package fields are references to the authoritative
internal tables. The reserved `dfhack` identity rule is the sole module-name
exception to these redirection mechanisms.

The normalized initial configuration and provider registry are immutable from
construction. This does not make the private runtime `package` immutable; code
may intentionally alter its bed-local loader state using normal Lua mechanisms.

These defaults cannot remove every declaration. An offline test for code that
uses real DFHack globals or host modules must still provide fakes,
providers, or a live adapter. DwarfSpec should fail clearly in that
case instead of installing a large, incomplete fake DFHack runtime.

Provider factories, class providers, dependency lists, scopes, multi-providers,
and automatic mocks should not be in the initial contract. A test can construct
a fake table before creating the bed. Additional strategies should be added
only if real consumer tests demonstrate a need that ordinary Lua construction
cannot meet.

## Active-source consumer contract

TestBed behavior is verified against the active DwarfSpec source repository.
Packaging qualification belongs to the repository-wide release process and is
not a TestBed completion gate.

The active source tree must expose the framework-neutral entry point directly:

```lua
local TestBed = require('dwarfspec.testbed')
```

`dwarfspec.testbed` and every internal resolver or environment module it needs
must be production modules beneath `src/dwarfspec/`. The production module is
the authority for the canonical `dwarfspec.TestBedConfig` and
`dwarfspec.TestBed` annotations; `src/ds.d.lua` references that configuration
type from each tagged descriptor `ds.mount` overload. Source declaration checks
must fail if either declaration surface is absent or disagrees with the runtime
validator where LuaLS can express the runtime constraint.

Requiring `dwarfspec.testbed` in a normal Lua process must not:

- read or require `df`, `dfhack`, `gui`, or another DFHack-only module;
- require a running Dwarf Fortress or `dfhack-run`;
- depend on DwarfSpec's live host, scheduler, mount context, or `ds` object;
- install Busted hooks or require Busted globals;
- mutate process `package.path` or `package.preload`, or mutate unrelated
  entries in `package.loaded`; normal `package.loaded` entries created by Lua's
  `require` for `dwarfspec.testbed` and its implementation modules are allowed;
  or
- derive consumer module or script roots from the DwarfSpec checkout layout.

The core supports Lua 5.3 and Lua 5.4. The standalone core conformance suite is
performed only under Lua 5.4; Lua 5.3 is supported but has no dedicated
compatibility suite. A required live integration proof may incidentally execute
under the DFHack host's Lua version, but that smoke coverage does not constitute
full Lua 5.3 conformance verification. TestBed may be used from Busted, but
it must remain an ordinary pure-Lua library. Standalone callers may release its
graph explicitly with `bed:close()`, while the live mount adapter owns that
lifecycle automatically.

Offline verification must load `dwarfspec.testbed` from the active repository's
`src` tree and exercise consumer-owned modules and scripts from a separate
checked-in fixture root. The test harness may add the active `src` tree to its
Lua module path, but TestBed itself must not add a checkout-specific path or
derive consumer roots from the DwarfSpec repository layout.

Relative roots and `use_source` paths are resolved from the effective consumer
root. For framework-neutral `TestBed.new()`, that root is the process's current
directory. The contract is therefore to start Busted from the consumer project
root. For a TestBed-backed `ds.mount`, DwarfSpec supplies the active consumer
project root. TestBed does not independently discover a project root or accept
one through configuration. This is a resolution convention, not a containment
boundary: explicit absolute paths and later mutations to the private
`package.path` may intentionally resolve files elsewhere, with ordinary Lua
filesystem and symlink behavior.

For a TestBed-backed live mount, `ds.mount` creates the TestBed through
DwarfSpec's normal source-repository module-loading behavior. Its adapter
supplies and validates the active consumer-project root, adds the DFHack base
environment and permitted host module importer, and registers cleanup. TestBed
has no special checkout-path rule distinct from the rest of DwarfSpec.

Consumer production modules, fakes, fixtures, and specs remain in the consumer
project. They are resolved from that project's declared roots and are not
copied into DwarfSpec production source directories.

Completion requires two source-backed verification paths:

1. Run the repository's offline Lua 5.4 suite, including the checked-in
   consumer fixture, with no DFHack globals. The fixture must load both an
   ordinary `require`/`mkmodule` graph and an annotated `reqscript` graph from
   the active source tree.
2. Configure the live DFHack environment to use the active DwarfSpec source
   repository. Run one representative configured descriptor mount with a
   production-style module dependency, annotated script dependency, replacement,
   and real host providers; repeat it to prove fresh state and cleanup; then run
   one post-allocation constructor failure to prove real ownership unwinding.

Source declaration fixtures must prove that valid TestBed fields receive
completion and type checking, invalid statically representable field types are
rejected, and only tagged descriptor `ds.mount` overloads declare an optional
`dwarfspec.TestBedConfig`. Runtime validation remains authoritative for
structural constraints that LuaLS cannot express.

The live proof must record the resolved active source path and loaded-module
evidence so another DwarfSpec copy cannot be mistaken for the implementation
under test. The absence of a dedicated Lua 5.3 compatibility suite is not a
completion blocker; required live proof still runs under its actual host
interpreter.

### Standalone unit-test usage

The TestBed core must not require DFHack or Busted:

```lua
describe('controller', function()
    local bed

    before_each(function()
        bed = TestBed.new{
            imports={
                {
                    provide={kind='module', name='my_plugin.clock'},
                    use_value={
                        now=function() return 42 end,
                    },
                },
            },
        }
    end)

    after_each(function()
        bed:close()
    end)

    it('uses the declared clock', function()
        local controller = bed:require('my_plugin.controller')
        assert.equals(42, controller.timestamp())
    end)
end)
```

This keeps Busted responsible for hooks and assertions. `close()` should be
idempotent, clear bed-owned references, and set one shared closed-state sentinel
consulted by the public methods and every TestBed-owned `require`, `reqscript`,
`mkmodule`, `load`, `loadfile`, and `dofile` closure. Those operations fail after
close even when a caller retained a module environment or loader closure.
Already-created consumer functions, tables, and borrowed values remain usable;
TestBed cannot invalidate arbitrary values retained by callers. Explicit close
should be recommended for deterministic reference release, but an unclosed
standalone bed must not leave TestBed-owned global hooks or loader mutations
behind. A test that creates a bed entirely inside one `it` block can therefore
omit explicit close when it does not need deterministic release. This does not
clean up global or native side effects performed by the consumer module itself.

### Live component-test usage

A tagged module or script descriptor accepts a `dwarfspec.TestBedConfig` as its
optional final argument. Every descriptor mount makes `ds.mount` create and own
one fresh TestBed instance:

```lua
it('renders the stored value', function()
    ---@type dwarfspec.TestBedConfig
    local testbed = {
        imports={
            {
                provide={kind='module', name='my_plugin.storage'},
                use_value={
                    read=function() return 'test value' end,
                },
            },
        },
    }

    ds.mount({
        kind='module',
        name='my_plugin.save_panel',
        export='SavePanel',
    }, {
        title='Saved value',
    }, testbed)

    assert.equals('test value', ds.get('status'):text())
end)
```

The created bed is private to the mount. On unmount or example cleanup,
DwarfSpec unmounts the component before closing the bed. Callers that need to
construct or reuse a TestBed instance directly do so only through the
standalone `TestBed.new(config)` API; instantiated beds are not valid mount
arguments. The initial public API does not expose graph inspection.

An ordinary class mount uses the existing mount implementation and creates no
TestBed. It accepts no TestBed configuration. Already-created component
instances are rejected because DwarfSpec cannot own their construction. A
module- or script-descriptor mount is inherently TestBed-backed: when its final
configuration is omitted, DwarfSpec creates the required bed from the fixed
defaults. This keeps ordinary class calls free of unused TestBed lifecycle work
while retaining a concise logical-name form.

If configuration validation, bed creation, construction, or mounting fails,
`ds.mount` must immediately unwind every resource it created before reporting
the failure. The returned value remains the mounted root subject; the bed does
not replace the ordinary component-test interaction API.

A descriptor overload resolves `kind='module'` through
bed-local `require`, or `kind='script'` through bed-local `reqscript`, using its
logical `name`, then selects the optional exact `export`.
When `export` is omitted, the loaded value must itself be a supported component
class. This is the overload that allows configuration passed directly to
`ds.mount` to affect the component's own module graph.

The descriptor requirement makes the ownership boundary explicit: component
resolution and construction occur inside the mount-created graph. The API must
not offer a configuration-bearing class or instance overload that suggests an
already-loaded component can retroactively observe replacements.

## Required module semantics

### Bed-local `require`

Every source module must execute with a `require` closure owned by its bed.
Nested imports therefore remain in the same module graph.

Each bed should have its own equivalents of:

- `package.loaded`;
- `package.preload`;
- `package.searchers`;
- `package.path`, `package.config`, and `package.searchpath`;
- a loading-state map;
- source and result records; and
- module environments created by `mkmodule`.

TestBed-owned loading must not mutate process-global `package.path`,
`package.loaded`, or `package.preload`. A `use_host` provider, including a
synthesized component provider, explicitly delegates to host `require` or
`reqscript` and may therefore populate or reuse the corresponding host cache;
TestBed does not restore that borrowed host state. The bed-local `package` is
private, mutable, and authoritative for that bed's `require`. Its initial
`searchers` contain a private preload searcher, the exact-provider searcher, and
a Lua source searcher using its private `path`. Code may mutate entries in the
authoritative `loaded` and `preload` tables and may replace or mutate `searchers`
and `path`; later bed-local calls for non-reserved module names must observe
those changes. As in native Lua, assigning a different table to
`package.loaded` or `package.preload` does not replace the internal table used by
`require`. The reserved `dfhack` name is resolved before these mechanisms and
cannot be redirected by them. `config` and `searchpath` must match the running
Lua version. The bed does not inherit host searchers or host `package.path`; its
initial path is constructed from `module_roots`.

The environment guarantees in this proposal apply to loaders compiled or
installed by TestBed. Replacing a private searcher or installing a preload
function created outside the bed is an explicit loader escape: TestBed invokes
that function but cannot rewrite the globals or dependencies already captured
by its closure.

The private package must not expose a working host `cpath` or `loadlib`. A
genuine DFHack native plugin crosses the boundary only through an explicit
`use_host` provider. Tests may replace any native-plugin token with an in-memory
`use_value` mock or a pure-Lua `use_source` shim; neither strategy attempts to
load or recreate the native binary.

Except for the bounded unpublished-cycle failure and reserved `dfhack` identity
rules documented below, bed-local `require` follows the semantics of the running
Lua version. A non-`nil`, non-`false` `package.loaded[name]` value is returned
immediately.
Otherwise the searchers supply and invoke a loader. If the loader returns a
non-`nil` value, that return value is assigned to `package.loaded[name]`,
overriding a different assignment made by the loader. If the loader returns
`nil`, its assignment to `package.loaded[name]` is preserved; if the entry is
still `nil`, `require` assigns `true`. An explicit cached or returned `false`
causes the next call to load again. Searchers pass loader data as the loader's
second argument. On Lua 5.4, a load that invokes a searcher also returns that
loader data as the second result; a cache hit has no loader data. Lua 5.3 does
not return loader data from `require`.

Initial TestBed searchers use deterministic loader data:

- the private preload searcher uses `":preload:"`, matching native Lua;
- root-loaded Lua source and `use_source` use the normalized resolved filename;
- `use_value` uses `":testbed:use_value:<kind>:<name>"`;
- `use_host` uses `":testbed:use_host:<kind>:<name>"`; and
- `use_existing` uses `":testbed:use_existing:<kind>:<name>"` for the alias
  token rather than forwarding the target token's loader data.

The active-loading map is checked only after the ordinary cache lookup. A module
that publishes a non-`nil`, non-`false` value in `package.loaded` before re-entry
therefore supports the cycle through ordinary Lua cache semantics. If a module
is already loading without such a published value, TestBed replaces native
Lua's eventual recursion-limit failure with a deterministic circular-`require`
error containing the bounded dependency chain. This changes how an unpublished,
already-doomed cycle fails, not which successfully loadable cycles are accepted.
TestBed does not preallocate a generic environment for every ordinary module and
does not roll back cache assignments if a loader later fails. It always clears
the module's active-loading marker while unwinding success or failure, so a
later call retries whenever ordinary cache semantics do not already provide a
result.

While `package.loaded[name]` retains a non-`nil`, non-`false` result, repeated
calls in one bed return that same identity. A cached `false` deliberately does
not provide this guarantee because Lua semantics reload it. Two beds loading
the same pure-Lua source must produce distinct bed-created module tables,
classes, closures, and module-local state.

### Module environments and `mkmodule`

DFHack's documented module convention is:

```lua
local _ENV = mkmodule('my_plugin.controller')

function run()
    -- ...
end

return _ENV
```

The TestBed must provide a bed-local `mkmodule`. It should return the same
environment for repeated calls with the same name inside one bed and a
different environment in another bed. `mkmodule(name)` immediately publishes
that environment as `package.loaded[name]`, allowing an ordinary module to opt
into Lua-compatible partially initialized state during a circular import.

DFHack native plugin modules are not recreated by bed-local `mkmodule`.
Resolving a genuine `plugins.*` module with `use_host` borrows the host module,
including its native exports, as one shared value. `use_value` can provide an
in-memory fake, and `use_source` can load a pure-Lua shim for the same token.
Such host modules keep host identity, caches, nested dependencies, and
mutations, and `bed:close()` does not restore them.

The environment chain should be:

```text
module environment
├── _G -> module environment
└── __index -> TestBed base facade
                 └── reads and ordinary writes -> bed-owned base backing
```

The module environment should receive bed-local `require`, `reqscript`,
`mkmodule`, and `package`, plus environment-bound `load`, `loadfile`, and
`dofile` closures. Its `_G` must point to that same module environment. This
preserves normal Lua expectations for `_G.foo` versus a direct global `foo`
while keeping writes out of the process global table.

The TestBed base facade is stable and mutable for ordinary keys. Reading through
it resolves the bed-owned base backing, and assigning an ordinary key through
`dfhack.BASE_G` updates that backing so every module in the same bed observes
the change. Loader-owned reserved keys resolve only to TestBed's implementations
or rejecting functions and cannot be assigned through the facade. Bed-local
`rawget`, `rawset`, `next`, and `pairs` must recognize the base facade, operate
on its backing for ordinary keys, and preserve the same reserved-key write
rules. The facade's metatable is protected from ordinary `getmetatable` and
`setmetatable` replacement. Direct assignment to a module global still writes
only that module's environment; code uses `dfhack.BASE_G` when it deliberately
wants a bed-wide global. The real host base is never mutated. The documented
`debug` and borrowed native-function escapes remain outside this compatibility
guarantee.

At construction, a standalone bed shallow-copies this explicit standard set
from the running interpreter: `_VERSION`, `assert`, `collectgarbage`, `error`,
`getmetatable`, `ipairs`, `next`, `pairs`, `pcall`, `print`, `rawequal`,
`rawget`, `rawlen`, `rawset`, `select`, `setmetatable`, `tonumber`, `tostring`,
`type`, `xpcall`, and the `coroutine`, `debug`, `io`, `math`, `os`, `string`,
`table`, and `utf8` libraries. Lua 5.4 also contributes `warn`. Library tables
and other referenced values are borrowed rather than recursively copied.
TestBed supplies its own `_G`, `require`, `package`, `mkmodule`, `reqscript`, and
`dfhack` integrations and installs the environment-bound dynamic-loading
closures described below. It wraps `rawget`, `rawset`, `next`, and `pairs` only
to preserve ordinary behavior for the TestBed base facade described above. It
does not copy arbitrary process `_G` entries.

A live mount starts with the same standard set, then shallow-snapshots every raw
key and value present in the active `dfhack.BASE_G` except the versioned reserved
loader names. Configured ordinary `globals` are applied over that snapshot, and
TestBed-owned reserved bindings are installed last. There is no dynamic
read-through to the live base after construction. Mutable tables, functions,
userdata, and other values captured by the snapshot remain borrowed state; the
real host `dfhack.BASE_G` table is not exposed.

Configured `globals` are shallow-copied into the bed base and can replace
ordinary runtime-base values, including `df`, constants, and test-specific
facades. They must not replace loader-owned `_G`, `require`, `reqscript`,
`mkmodule`, `package`, `load`, `loadfile`, `dofile`, `reload`,
`script_environment`, or script-owned `dfhack_flags`. A configured `dfhack`
table is the complete backing API for a TestBed-owned facade, not the facade
itself. When it is supplied, missing ordinary fields remain absent rather than
silently falling through to the live object. When it is omitted, a live adapter
uses the permitted live DFHack object as the backing API, while an offline bed
uses an empty backing API. The facade shadows every reserved loader field, and
its `BASE_G` field is the stable mutable TestBed base facade rather than the real
host base. Writes to reserved `dfhack` facade fields are rejected; writes to
ordinary `dfhack` fields affect the selected borrowed DFHack backing table.
Ordinary writes through `dfhack.BASE_G` instead affect the bed-owned shared base
backing described above. Tables supplied through `globals` are borrowed mutable
state and are not restored by `bed:close()`.

The `dfhack` global binding initially visible to every module and bed-local
`require('dfhack')` must return exactly the same TestBed-owned facade. A module
can still deliberately shadow its own global binding through normal Lua
assignment. This is a reserved-name exception to otherwise normal Lua package
mutability: the private package may expose `package.loaded.dfhack` for
compatibility, but changing that entry, installing `package.preload.dfhack`,
replacing searchers, or adding a matching source path must not make
`require('dfhack')` diverge from the global facade. Resolving the reserved name
happens before the ordinary package algorithm and never invokes host `require`.
Explicitly borrowed host modules may still retain or obtain the real host
`dfhack` object within their host-owned dependency graph.

Each module and source-loaded script environment receives closures bound to that
environment. Bed-local `load(chunk, chunkname?, mode?, env?)` and
`loadfile(filename, mode?, env?)` preserve the running Lua version's signatures,
honor an explicitly supplied environment, and otherwise compile into the
closure's owning module or script environment. Bed-local `dofile(filename)`
loads and executes the file in that same owning environment and preserves the
chunk's ordinary return values. The unbound `load`, `loadfile`, and `dofile`
fields visible directly through the shared `dfhack.BASE_G` facade fail with a
clear unsupported-operation error; callers use the environment-local global
bindings instead. Explicit file paths follow ordinary Lua filesystem behavior;
TestBed does not claim physical containment.

TestBed must publish a versioned reserved-loader policy for the supported
DFHack version. Known loader entry points visible through the bed base, the
private `package`, or the delegated `dfhack` facade must either remain inside
the bed graph or fail clearly. Ordinary non-loader DFHack APIs may delegate to
the host. The guarantee is intentionally scoped to the documented import APIs
of supported DFHack versions; it is not an open-ended promise to recognize
every future function with loader-like behavior. The initial policy is:

| Entry point | TestBed behavior |
|---|---|
| `_G` | Refer to the current module environment, not process `_G`. |
| Initial global `dfhack` and `require('dfhack')` | Return the same TestBed-owned facade; resolve before mutable package mechanisms and never through host `require`. |
| `dfhack.BASE_G` | Return the stable TestBed base facade. Ordinary writes update bed-wide globals; reserved loader keys reject writes; the real host base is untouched. |
| `require` | Resolve through the bed-local ordinary-module graph. |
| `mkmodule` | Return the stable environment owned by this bed and module name. |
| `reqscript` and `dfhack.reqscript` | Resolve through the bed-local script-module graph. |
| Module- and script-global `load`, `loadfile`, and `dofile` | Use closures bound to the owning environment, honoring explicit `load` and `loadfile` environment arguments. |
| `dfhack.BASE_G.load`, `dfhack.BASE_G.loadfile`, and `dfhack.BASE_G.dofile` | Fail as unsupported because the shared base facade has no single owning module environment. |
| `dfhack_flags` | Be absent from ordinary module environments; source-loaded script environments receive their own table with `module=true`; the shared base facade rejects replacement. |
| `reload` and `dfhack.reload`, if present | Fail as unsupported; a bed-local reload API is deferred. |
| `script_environment` and `dfhack.script_environment`, if present | Fail as unsupported; they must not bypass `reqscript` annotation and cache rules. |
| `package.loaded`, `package.preload`, `package.searchers`, `package.path`, `package.config`, and `package.searchpath` | Use the mutable, authoritative bed-local package for non-reserved names; none can redirect `dfhack`. |
| `package.cpath` and `package.loadlib` | Do not expose working host native loading; native modules require explicit providers. |

The live adapter must exclude reserved names from the runtime snapshot and
install raw bed-owned functions or explicit rejecting functions for those names
after applying configured ordinary globals. A configured or live `dfhack`
facade must likewise shadow reserved fields before delegating ordinary API
fields to its selected backing object. This prevents a missing bed-local field
from reaching a similarly named host function.

`dfhack.run_script`, `dfhack.run_command`, and comparable command-execution
APIs are not dependency imports. A live adapter may delegate them when a test
intentionally exercises real host behavior, but any scripts they execute and
all resulting native, registration, file, timer, plugin, input, or gameplay
effects are outside the bed graph and are not reversed by `bed:close()`.
Standalone beds expose no such live execution functions unless the caller
supplies an explicit fake through configured globals.

This is compatibility isolation, not a security boundary. The `debug` library,
borrowed mutable tables, userdata, and native functions can still escape or
mutate state.

### Host module imports

Live components need real DFHack modules such as `class`, `gui`, and
`gui.widgets`. A TestBed-backed `ds.mount` should make the small documented
component profile available by default so the usual component test does not
repeat that boilerplate. Every other host module should be borrowed only
through an exact `TestBedHostImport` provider supplied in `imports`.

The component-import set is part of DwarfSpec's public compatibility contract.
It must be versioned, tested, and identified as borrowed in applicable loader
errors. It is not permission to fall back to arbitrary host `require`.
Framework-neutral `TestBed.new()` has no live importer or default host imports;
any `use_host` provider therefore fails clearly offline.

A borrowed module is shared host state:

- invoking its host loader may populate the host module or script cache;
- TestBed does not reload or unload it;
- its own nested dependencies were resolved by the host, not by the bed;
- its mutations are not reversed by `bed:close()`; and
- replacing a dependency in the bed cannot retroactively alter a borrowed
  module that already captured the host dependency.

This bounded default plus explicit boundary is preferable to silently falling
back to host `require`, which would make a missing test declaration pass in
live DFHack and fail in standalone Lua.

An exact `use_value` or `use_source` provider can replace a synthesized host
provider, including a native-plugin token. A source provider always loads its
declared pure-Lua shim and never attempts native loading. `use_existing`
inherits the resolution and identity of its target and does not create another
module instance.

Consumer source should not be loaded both globally and through a bed in the
same example. Duplicate class and singleton identities would make behavior
hard to reason about.

### DFHack script modules

DFHack distinguishes Lua library modules from importable scripts. `reqscript`
searches script paths, requires a `--@ module=true` declaration, supplies
`dfhack_flags.module`, returns the script environment, and supports circular
script dependencies.

That behavior should not be approximated by aliasing `reqscript` to
`bed:require()`.

Support for the modern annotated script-module form is required in the first
usable contract. It must use a separate operation and cache:

```lua
local bed = TestBed.new()
local script = bed:reqscript('internal/my_plugin/worker')
```

The `script_roots` field supplies conventional discovery, while exact script
values, files, host borrows, and aliases use the same `imports` provider array
with `provide.kind='script'`. A source-loaded script environment must be
allocated and cached immediately before its chunk executes so supported
circular script imports can observe the same partially initialized environment.
TestBed validates `--@ module=true` and gives that environment its own raw
`dfhack_flags` table with `module == true`; ordinary module environments do not
receive that binding. `use_value`, `use_host`, and `use_existing` do not execute
a TestBed-owned script chunk and therefore do not inject or modify
`dfhack_flags` in their returned tables. TestBed intentionally does not support
legacy `moduleMode`; DwarfSpec targets modern plugins and documents this as a
modern `reqscript` subset rather than complete historical emulation.
`use_source` does not bypass the annotation or environment rules; it changes
only which exact file supplies the script.

Every TestBed-loaded module and script environment must receive the bed-local
`reqscript` function so production code can use the ordinary unqualified form.
The `dfhack` value visible inside the bed must also expose the same bed-local
operation as `dfhack.reqscript` without modifying the borrowed process-global
`dfhack` table. Import-oriented `dfhack` fields follow the explicit loader
policy above; only non-import fields may delegate through the configured or
live DFHack facade.

Bed-local script resolution must be deterministic:

1. return the script value or environment already cached by this bed;
2. resolve an exact script provider from `imports`; a same-namespace
   `use_existing` resolves its target before allocating anything for the alias
   and caches the target's exact identity under the alias token;
3. search `script_roots` in declared order; or
4. fail with the script dependency chain.

An alias-only cycle fails with a bounded dependency chain. An environment is
preallocated only when TestBed is about to execute an actual source-backed
script, never merely because an alias token was requested. If annotation
validation or script execution fails, TestBed removes the preallocated script
cache entry and clears its active-loading marker while unwinding so a later call
can retry. Successfully preallocated environments remain cached and continue to
provide the documented circular-script identity.

TestBed must not silently fall back to the process-global DFHack `reqscript`.
That would reintroduce shared script caches and make an undeclared dependency
pass live while failing offline. A test can declare a provider or source root
for every script dependency it needs. `use_host` is the sole explicit request
to borrow the real host `reqscript` result, and it fails offline.

TestBed emulates the documented modern DFHack import-facing script semantics;
it does not claim to reproduce live script-path integration, mod activation,
save-specific path changes, or file-change hot reload. Tests for those
behaviors must call the
real DFHack `reqscript` outside TestBed. Keeping the module and script
namespaces separate preserves their different return, environment, cache, and
cycle contracts.

## Isolation guarantees

The public documentation should use precise levels instead of the unqualified
word "isolated".

| Boundary | TestBed guarantee |
|---|---|
| Bed-owned module cache | Private to one bed. Explicit host providers may populate or reuse a separate host cache. |
| Pure-Lua module state | Fresh when source is loaded by a fresh bed. |
| Dependency replacement | Exact and local to the bed graph. |
| Direct global writes | Retained in bed-owned environments. |
| Host `package` tables | TestBed-owned loaders do not modify them. Host providers may populate host caches through host loading. |
| Borrowed module tables | Shared; not restored. |
| Standard-library tables | Shared unless explicitly replaced. |
| DF globals and userdata | Shared when real values are supplied. |
| Timers, hooks, files, screens, plugins | Not automatically reversed by the loader. |
| Game effects caused by input or calls | Not reversed. |
| Malicious or unrestricted Lua | Not securely sandboxed. |

For live tests, DwarfSpec's existing mount, pointer, pause, speed, view,
registration, timer, and cleanup ownership remains additive to the module
guarantees. TestBed should never report those resources as isolated merely
because the module graph was closed.

## Architecture

The implementation should retain three boundaries:

```text
standalone Busted test ----\
                            -> dwarfspec.testbed -> resolver + environments
live ds.mount(descriptor, ..., testbed) -> adapter --/
                                |                     |
                                +-> component mount   +-> optional host imports
                                                      +-> source files
```

`dwarfspec.testbed` should own configuration validation, caching, loading,
dependency-chain errors, and close behavior. Small internal
resolver and environment modules are justified if they keep path handling
and Lua-environment construction independently testable.

The live mount adapter should:

- validate the descriptor overload's final `dwarfspec.TestBedConfig`
  independently from existing component and mount options;
- create one fresh bed for every tagged module or script descriptor, using the
  fixed defaults when configuration is omitted;
- leave ordinary class mounts TestBed-free and reject TestBed configuration on
  that overload;
- reject already-created component instances;
- provide the DFHack base environment and host importer;
- establish the active consumer project as the base for relative paths without
  claiming filesystem containment;
- resolve a logical module or script descriptor through the bed;
- otherwise pass the original class unchanged;
- pass the existing component options to the component-mount boundary
  unchanged;
- coordinate mount-before-bed cleanup order.

It should not contain the loader algorithm or a second component-mount
implementation. The graph behavior has a dedicated standalone conformance suite
under Lua 5.4. Lua 5.3 remains supported without a dedicated compatibility
suite; incidental execution by a live DFHack proof is integration smoke
coverage rather than full Lua 5.3 conformance verification.

All module names, provider tokens, and source-path values must be type-validated.
Relative paths use the effective project root, but explicit paths and private
package mutations retain ordinary Lua reach. Error messages should include the
requested token, resolution attempts, and dependency chain without dumping
unbounded tables or source.

## Usefulness by test type

| Test type | Expected value | Reason |
|---|---|---|
| Standalone unit tests for pure logic | High | Shared setup can load production modules with explicit fake DFHack dependencies. |
| Standalone unit tests for DFHack-style module state | High | Fresh `mkmodule` environments remove global cache surgery. |
| Live component tests with replaceable services | High | Real GUI classes can be imported while product collaborators are local fakes. |
| Live component tests of rendering and input | Moderate | TestBed improves setup and state freshness, but rendering still requires the live host. |
| Native game UI and gameplay integration | Low | Most relevant state is native and shared, not module-local. |
| Overlay discovery and script-path integration | Negative if substituted | Those tests must exercise real registration, path precedence, and cleanup rather than a TestBed resolver. |

The feature will be most valuable if consumer code already has meaningful
module seams. It cannot make tightly coupled code testable without explicit
dependencies or replaceable module imports.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| The API promises more isolation than it provides. | Publish the isolation table above and identify borrowed providers in relevant loader errors. |
| Live and standalone defaults hide an accidental portability difference. | Use one core loader, keep the component-import set small and exact, and identify every host provider as borrowed. |
| A conventional default root selects an unintended duplicate module. | Use a fixed documented precedence, report the selected source, and allow explicit roots to replace the convention. |
| The runner starts outside the consumer project. | Fail with the effective current directory and attempted roots; require standalone Busted to start at the consumer project root. |
| A module escapes through global `require`, `package`, `loadfile`, or `_G`. | Install bed-local functions and a private authoritative package in every source environment. |
| A module escapes through DFHack `reload`, `script_environment`, or another known host import function. | Maintain a versioned policy for supported DFHack loader APIs, with a bed-local implementation or explicit rejection for each reserved entry point. |
| A module replaces a loader through `dfhack.BASE_G`. | Route ordinary base writes to bed-owned shared globals, but reject normal and bed-local `rawset` writes to reserved loader keys. |
| The initial global `dfhack` binding and `require('dfhack')` expose different APIs. | Reserve the `dfhack` module token, configure mocks only through `globals.dfhack`, resolve it before the mutable package algorithm, and return one facade from both access forms. |
| A fake silently masks a misspelled production module. | Validate provider tokens, freeze the provider registry, and identify the failed resolution strategies in the error. |
| Circular imports return inconsistent state. | Check the cache before the active-loading map, honor explicitly published partial state, and replace only native Lua's doomed recursive failure with a bounded circular-import chain. |
| A failed load poisons later resolution. | Clear active-loading markers on every exit, retain only ordinary module cache assignments, and remove TestBed-preallocated script environments after failure. |
| A borrowed GUI class and a bed-loaded copy have incompatible identities. | Borrow DFHack framework modules exactly and warn against loading them from source roots. |
| A test passes an already-loaded class or instance and expects replacements to affect captured dependencies. | Reject TestBed configuration on class mounts, reject instance mounts, and require a tagged module or script descriptor for TestBed-backed construction. |
| A TestBed configuration table is confused with component constructor options. | Keep `dwarfspec.TestBedConfig` in a dedicated final parameter instead of inferring intent from table keys. |
| Cleanup releases the graph while a mounted object still references it. | Register bed cleanup before mount cleanup and drain in LIFO order. |
| Tests become tied to TestBed instead of improving production seams. | Keep providers aligned with existing Lua module and script names and avoid constructor rewriting. |
| Explicit paths resolve outside the consumer project. | Document that project-relative defaults are convenience, not security; do not claim physical containment beyond ordinary Lua path behavior. |
| `reqscript` compatibility becomes accidental and incomplete. | Define and test the modern supported subset explicitly, including the deliberate omission of legacy `moduleMode`. |

## Alternatives considered

### Continue manipulating global `package.loaded`

This is small but does not scale. Each test must know the complete transitive
module set, preserve preexisting values, restore them after failures, and avoid
colliding with another test's globals. It also gives standalone and live tests
different conventions.

### Clear all consumer modules before each example

This improves freshness but still mutates global process state. It can invalidate
objects held by DwarfSpec, Busted, DFHack, another project, or a mounted
component. File-path ownership is also ambiguous for modules resolved through
custom searchers.

### Run every test in a fresh Lua process

This is the strongest standalone boundary and should remain available for
untrusted or highly stateful code. It cannot cheaply provide live component
tests inside the one DFHack core interpreter, and process startup alone does
not provide controlled dependency replacement.

### Build a full dependency-injection container

This would require production modules to adopt framework tokens, provider
factories, or constructor conventions that DFHack and ordinary Lua do not use.
The proposed provider tokens merely identify existing module and script loader
names; production code still calls normal `require` and `reqscript`. A general
container would solve a different problem and create substantial framework
coupling.

### Use only source-file environment injection

Loading one file with a custom `_ENV` is insufficient because nested
`require()` calls re-enter the process-global graph. Isolation must own the
transitive loader.

## Recommended delivery

The first usable increment should contain:

- zero-argument framework-neutral `TestBed.new()`;
- canonical `dwarfspec.TestBedConfig` and `dwarfspec.TestBed` authoring types in
  the active source repository;
- `TestBed.new(config)` annotated and runtime-validated against that canonical
  configuration type;
- the optional final `dwarfspec.TestBedConfig` parameter only on tagged module-
  and script-descriptor `ds.mount` overloads;
- descriptors shaped as `{kind='module'|'script', name=..., export=...}` that
  resolve the component through the mount-created bed without a file path;
- no TestBed allocation or lifecycle change for ordinary class mounts, no
  configuration-bearing class overload, and no already-created instance mount;
- mount ownership of one fresh TestBed for every descriptor mount;
- the fixed project-layout defaults and documented live component-import set;
- optional `module_roots`, `script_roots`, `globals`, one typed `imports`
  provider array, and `component_imports=false` for disabling synthesized host
  providers on a mount;
- `use_value`, `use_source`, live-only `use_host`, and same-namespace
  `use_existing` provider strategies, with raw key-presence validation,
  non-`nil` `use_value` payloads, and exact script-alias identity;
- bed-local `require`, Lua-compatible cache and return semantics, module
  environments with module-local `_G`, a mutable authoritative private
  `package`, environment-bound `load`, `loadfile`, and `dofile`, and `mkmodule`;
- bed-local `reqscript` and `dfhack.reqscript`, with annotation validation,
  `dfhack_flags.module`, a separate script cache, supported circular script
  imports, and no legacy `moduleMode`;
- a versioned policy that masks known host `reload`, `script_environment`, and
  other reserved import entry points not implemented by the bed;
- one TestBed-owned `dfhack` facade shared by the initial global binding and
  `require('dfhack')`, backed exclusively by `globals.dfhack`, the permitted live
  object, or an empty offline object, with `dfhack.BASE_G` bound to the stable
  mutable TestBed base facade and the `dfhack` name resolved before mutable
  package mechanisms;
- immutable initial configuration from construction while the private runtime
  package remains mutable;
- idempotent `close` with one closed-state sentinel observed by every bed-owned
  public method and loader closure;
- bounded module and script dependency-chain errors;
- standalone unit coverage on Lua 5.4;
- documented Lua 5.3 support without a dedicated compatibility suite;
- atomic `ds.mount` TestBed cleanup integration with one configured live
  component proof, one consecutive fresh-state proof, and one representative
  post-allocation failure-unwind proof;
- source-tree declaration and Lua 5.4 unit proof;
- an offline consumer-shaped proof against the active source repository; and
- a live component proof against that same active source repository.

Reload APIs, factories, convenience Busted adapters, and diagnostic graph
inspection should be considered only after representative consumer tests
establish a need.

The existing run-level project path and eviction logic should remain in place
throughout. It supports ordinary specs and loads the spec files themselves;
TestBed is a narrower per-example composition tool.

## Prototype acceptance criteria

A prototype is successful only if it demonstrates all of the following:

- `TestBed.new()` loads a conventional consumer module and annotated script
  without a configuration table when Busted starts at the project root;
- `TestBed.new(config)` exposes completion and type checking for the canonical
  config, token, provider-union, and provider-strategy types from the active
  source repository, and `TestBed:require` exposes its Lua-version-dependent
  optional loader data result;
- only tagged module- and script-descriptor mount overloads expose the optional
  final `dwarfspec.TestBedConfig` parameter;
- ordinary class mounts use the canonical `dwarfspec.ComponentClass` authoring
  type, create no TestBed, reject a third TestBed argument, and retain their
  existing two-argument behavior;
- already-created component instances are rejected;
- every tagged descriptor mount creates and automatically closes one fresh bed,
  using fixed defaults when its configuration is omitted;
- descriptors use logical `(kind, name)` identity without requiring callers to
  specify a source-file path, and resolve component construction through the
  mount-created graph;
- component constructor options and TestBed configuration remain unambiguous
  even when they contain identical field names;
- every configuration field can be omitted independently, explicit root lists
  replace their defaults, and the component provider set can be disabled
  deterministically;
- `imports` accepts `use_value`, `use_source`, live `use_host`, and
  same-namespace `use_existing`; raw field presence recognizes
  `use_value=false`; and duplicate user tokens, `use_value=nil`, cross-namespace
  aliases, multiple strategies, unknown fields, and non-table script values are
  rejected;
- an import provider whose `provide` token is `{kind='module', name='dfhack'}`
  is rejected for every strategy;
- user providers replace synthesized component providers for the same token,
  while duplicate user providers remain errors and providers precede accidental
  source files with the same logical name;
- standalone `use_host` fails clearly, host imports are reported as borrowed,
  and `use_existing` returns the exact target identity;
- genuine native `plugins.*` modules can be borrowed with `use_host`, faked
  with `use_value`, or replaced by a pure-Lua `use_source` shim without invoking
  native loading;
- standalone beds copy only the documented standard-Lua bindings, live beds
  snapshot every non-reserved raw `dfhack.BASE_G` binding at construction, and
  neither form dynamically reads later process-global or host-base additions;
- configured globals replace ordinary runtime-base values, reserved
  loader-owned names are rejected, and `globals.dfhack` supplies the complete
  ordinary-API backing mock for the TestBed-owned facade;
- an unmodified module-global `dfhack` binding and `require('dfhack')` return
  exactly the same facade; ordinary `dfhack.BASE_G` writes are visible across
  the bed without changing the real host base; reserved base and `dfhack` facade
  fields reject normal and bed-local `rawset` writes; the base facade's
  metatable rejects ordinary replacement; and configured mocks cannot fall
  through to omitted live API members;
- mutating private `package.loaded.dfhack`, installing
  `package.preload.dfhack`, replacing searchers, or adding a matching source path
  cannot redirect `require('dfhack')` away from that facade, while ordinary
  package mechanisms remain mutable and authoritative for every other name;
- `require('dwarfspec.testbed')` succeeds from the active source tree without
  DFHack globals;
- loading the framework-neutral TestBed module does not load the live host,
  scheduler, mount, `ds`, or Busted integration modules;
- every public and internal TestBed production module remains under `src/`,
  while tests and fixtures remain outside production source directories;
- two beds load the same stateful source without sharing module state;
- nested dependencies use the same bed and observe exact replacements;
- TestBed-owned loading leaves process `package.path`, `package.preload`, and
  unrelated `package.loaded` entries unchanged beyond the normal cache entries
  created when requiring TestBed itself, while host providers are explicitly
  permitted to populate or reuse host module and script caches;
- the bed-local `package` owns mutable `loaded`, `preload`, `searchers`, and
  `path` tables plus compatible `config` and `searchpath`; entry mutations to
  `loaded` and `preload` and replacement or mutation of `searchers` and `path`
  affect only subsequent non-reserved loads in that bed, while replacing the
  exposed `package.loaded` or `package.preload` table reference does not replace
  the internal table used by `require`;
- bed-local `require` honors the running Lua version's cache, loader return,
  `package.loaded` assignment, and `false` semantics; on Lua 5.4, initial
  searchers supply the documented deterministic loader-data values and a cache
  hit returns no loader data;
- the bed-local package cannot invoke host `cpath` or `loadlib` native loading;
- real host sentinels for `reload`, `dfhack.reload`, `script_environment`, and
  `dfhack.script_environment` are never invoked by TestBed-loaded code and
  instead produce the documented unsupported-operation failures;
- environment-local `load`, `loadfile`, and `dofile` default to their owning
  module or script environment, explicit `load` and `loadfile` environment
  arguments are honored, their ordinary return values are preserved, and the
  unbound variants on `dfhack.BASE_G` fail clearly;
- no reserved loader field for the supported DFHack version omitted from the
  bed base or delegated `dfhack` facade can fall through to the real host
  `dfhack.BASE_G` or the process-global loader;
- delegated live command-execution APIs are reported as host effects rather
  than as members of the bed-local module graph;
- `mkmodule` returns stable state within one bed and fresh state across beds,
  immediately publishes its environment in the private module cache, and
  permits an ordinary circular import to observe that published environment;
- an ordinary circular import without a non-`nil`, non-`false` value already
  published in `package.loaded` fails with a bounded circular-`require` chain
  instead of reaching native Lua's recursion-limit failure, while a published
  cycle succeeds with native cache behavior;
- success and failure both clear ordinary module active-loading markers, and a
  failed module can be retried whenever its ordinary cache state does not
  already provide a result;
- `bed:reqscript` and TestBed-local `dfhack.reqscript` return the same
  bed-owned script environment for one script name;
- source-loaded annotated scripts receive their own raw `dfhack_flags` table,
  observe `dfhack_flags.module == true`, and do not run command-only side effects
  below their module guard; ordinary modules receive no `dfhack_flags`, and
  value, host, and alias providers do not inject one into returned tables;
- missing `--@ module=true` declarations fail before script execution;
- legacy `moduleMode` is not recognized and the resulting error identifies the
  supported modern annotation contract;
- supported circular script imports share their preallocated environments
  without entering the process-global script cache;
- script `use_existing` aliases allocate no alias environment and cache the
  target's exact identity, while alias-only cycles fail with a bounded chain;
- annotation or execution failure removes the TestBed-preallocated script cache
  entry and active-loading marker so a later `reqscript` call can retry;
- two beds load the same script source without sharing script globals;
- each module's `_G` is its own module environment, direct and `_G`-qualified
  module writes agree, and neither reaches process `_G`;
- missing modules, missing scripts, and dependency cycles produce bounded,
  actionable chains;
- a live host module outside the documented component-import set fails unless
  explicitly provided with `use_host`;
- exact host providers preserve the real DFHack class identities needed by
  `ds.mount`;
- a descriptor-loaded component observes providers in the supplied TestBed
  configuration before its defining module is loaded;
- relative default roots resolve from the effective project root, while
  explicit source paths, symlinks, and private `package.path` mutations are not
  rejected under a nonexistent physical-containment guarantee;
- a separate checked-in consumer fixture runs offline Busted tests against the
  active source repository and consumer-owned production modules plus annotated
  script modules;
- a production-style widget from that consumer fixture is loaded through a
  TestBed configuration with module and script dependencies, one replacement,
  and real host providers, then mounts and interacts in live DFHack using the
  same active source repository;
- a consecutive mount of that widget observes fresh module and script state,
  and both successful mounts unmount and close their beds exactly once;
- one constructor failure after TestBed allocation leaves the mount-owned bed
  observably closed before control returns and leaves the host usable without
  active components, screens, or owned run resources;
- after `close`, public methods and retained TestBed-owned loader closures fail
  through the shared closed-state sentinel, while already-created consumer
  values remain ordinary caller-owned references; and
- live examples require no process-global registry of active TestBeds.

The prototype should be evaluated against at least one real consumer module,
not only synthetic fixtures. The main success measure is reduced setup and
cleanup code while retaining clear dependency and ownership boundaries.

## Verdict

The proposed system has a favorable usefulness-to-complexity ratio if it stays
focused on module-graph ownership.

It should be described as "a TestBed-local Lua module and script graph for
tests." It should not be described with an unqualified isolation claim, as a
complete sandbox, or as a mechanism that makes live DFHack behavior portable
to standalone Lua.

The best design is an instance-scoped, strict, deterministic loader shared by
standalone and live tests. Standalone tests create the instance directly;
component tests use a tagged logical module or script descriptor and can pass
the same strongly typed configuration as its optional final argument.
Descriptor mounts always create a bed because source resolution and component
construction must occur inside it. Existing class mounts remain TestBed-free,
configuration-bearing class mounts and already-created instance mounts are not
supported, and every mount-created TestBed belongs to DwarfSpec cleanup. That
design provides controlled composition and fresh per-test state without
imposing an unused loader lifecycle on ordinary class mounts.

## References

- [Angular dependency providers](https://angular.dev/guide/di/defining-dependency-providers)
- [Lua 5.3 reference manual](https://www.lua.org/manual/5.3/manual.html)
- [Lua 5.4 reference manual](https://www.lua.org/manual/5.4/manual.html)
- [DFHack Lua module and script API](https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html)
- [DFHack modding guide](https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html)
