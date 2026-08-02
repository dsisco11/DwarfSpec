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
does not provide an isolated module graph for one example:

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
replacement, module retrieval, and deterministic reset behavior.

Its core principles should be:

- make the conventional case work with `TestBed.new()` and with the optional
  TestBed definition on every `ds.mount` overload;
- declare the environment before loading the subject;
- prefer real dependencies unless a test explicitly replaces one;
- use fixed, documented defaults rather than scanning for a plausible layout;
- freeze configuration after the first load;
- create fresh state for each example; and
- make teardown deterministic.

Ordinary Lua modules obtain dependencies through `require`, globals, and
captured values. A static TestBed API would add another global mutable registry
on top of `package.loaded`, which is the state the feature is intended to
avoid.

DwarfSpec should therefore expose ordinary TestBed instances to standalone
callers. Every component-mount overload should accept the same declarative
configuration type through one optional final parameter. Supplying that
configuration creates a mount-owned TestBed. Omitting it from an ordinary
class or instance mount preserves the existing mount path and does not create
a TestBed. A source-backed mount necessarily creates a TestBed because the bed
must resolve the component source; omitted configuration on that form means
the fixed defaults. The mount command never accepts an instantiated TestBed.

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
    modules={
        ['my_plugin.storage']=fake_storage,
    },
}

ds.mount({
    module='my_plugin.save_panel',
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
    modules={
        ['my_plugin.clock']=fake_clock,
    },
}

local controller = bed:require('my_plugin.controller')
```

All configuration fields should be optional:

| Field | Default | Customization |
|---|---|---|
| `module_roots` | `src/scripts_modinstalled`, then `src`, then `.` beneath the project root. | Replacement ordered roots for `name.lua` and `name/init.lua`. |
| `modules` | Empty. | Exact module-name to module-value replacements. |
| `sources` | Empty. | Exact module-name to source-file mappings. |
| `globals` | Curated Lua plus a minimal bed-local `dfhack.reqscript` facade offline; curated Lua plus the live DFHack facade live. | Additional globals and replacements for non-reserved runtime globals. |
| `component_imports` | `false` offline; `true` for a TestBed-backed `ds.mount`. | Enables or disables the documented foundational host-module set. |
| `imports` | Empty. | Exact host modules added independently of `component_imports`. |
| `script_roots` | `src/scripts_modinstalled` beneath the project root. | Replacement ordered roots searched by bed-local `reqscript`. |
| `scripts` | Empty. | Exact script-name to script-environment replacements. |
| `script_sources` | Empty. | Exact script-name to source-file mappings. |

### Authoring-time type contract

The configuration must be one canonical public type named
`dwarfspec.TestBedConfig`. It must be shipped in the installed rock and visible
to Lua language servers when a consumer requires `dwarfspec.testbed` or uses
the shipped `ds.d.lua` declaration.

The production module should carry the authoritative annotations:

```lua
---Configures module and script resolution for one TestBed.
---@class dwarfspec.TestBedConfig
---@field module_roots? string[]
---@field modules? table<string, any>
---@field sources? table<string, string>
---@field globals? table<string, any>
---@field component_imports? boolean
---@field imports? string[]
---@field script_roots? string[]
---@field scripts? table<string, table>
---@field script_sources? table<string, string>

---Owns one isolated module and script graph.
---@class dwarfspec.TestBed
local TestBed = {}

---Creates an isolated module environment from a typed configuration.
---@param config? dwarfspec.TestBedConfig
---@return dwarfspec.TestBed
function TestBed.new(config) end

---Loads one Lua module through this TestBed.
---@param name string
---@return any
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
---Identifies a component exported by a bed-local Lua module.
---@class dwarfspec.ModuleComponentSource
---@field module string
---@field export? string

---Identifies a component exported by a bed-local DFHack script module.
---@class dwarfspec.ScriptComponentSource
---@field script string
---@field export? string

---Selects a component source that must be resolved through a TestBed.
---@alias dwarfspec.TestBedComponentSource
---| dwarfspec.ModuleComponentSource
---| dwarfspec.ScriptComponentSource
```

Every current and future `ds.mount` overload must append that optional input:

```lua
---Mounts one owned component or complete screen.
---@overload fun(source: dwarfspec.TestBedComponentSource, options?: dwarfspec.MountOptions, testbed?: dwarfspec.TestBedConfig): dwarfspec.Subject
---@param component any
---@param options? dwarfspec.MountOptions
---@param testbed? dwarfspec.TestBedConfig
---@return dwarfspec.Subject
function DS.mount(component, options, testbed) end
```

Keeping TestBed as the final parameter preserves every existing two-argument
mount call and avoids guessing whether an arbitrary Lua table is a component's
constructor options or a TestBed configuration. When no component options are
needed, the unambiguous call is `ds.mount(Component, nil, testbed)`. The
declaration file should publish an annotated overload for every supported
component class, component instance, module source, and script source form,
with `dwarfspec.TestBedConfig` in the same optional final position. Omitting
that parameter from a class or instance overload preserves the current
TestBed-free behavior. Supplying it creates one fresh mount-owned TestBed.
Module- and script-source overloads always create one fresh mount-owned
TestBed, using the fixed defaults when configuration is omitted, because that
bed resolves the component itself.

This is a strong authoring contract for plain Lua tables, not a new wrapper
builder. Runtime code must apply the same schema: reject unknown fields and
invalid field types, copy mutable configuration containers, normalize paths,
and freeze the normalized configuration before the first load. Static
annotations and runtime validation must be tested from the installed rock so
the editor contract cannot silently diverge from executable behavior.

The default roots are a fixed convention, not an open-ended directory scan.
Missing default directories are skipped. An error must list the effective
roots that were tried. Explicitly providing a root list replaces its default,
including with an empty list when a source-only bed is desired.

The initial documented live component import set should contain only
common, foundational DFHack library modules: `class`, `utils`, `gui`,
`gui.widgets`, and `gui.dwarfmode`. It must not include registry- or
scheduler-oriented modules such as `plugins.overlay`, `plugins.eventful`,
`repeat-util`, or `script-manager`. Tests that need one of those shared host
modules must name it in `imports`. The list is enabled by default for beds
created by `ds.mount` and disabled by default for standalone beds.
`component_imports=false` disables the default set. Exact names in `imports`
remain enabled independently, allowing a fully custom host-import allowlist.

Resolution should be deterministic:

1. return a value already cached by this bed;
2. use an exact value from `modules`;
3. use an exact file mapping from `sources`;
4. borrow an exact name in the enabled component-import-plus-`imports`
   allowlist;
5. search `module_roots` in declared order; or
6. fail with the complete dependency chain.

This order reserves enabled host-module names against accidental consumer-root
shadowing while preserving intentional replacements through the explicit
`modules` and `sources` fields.

Configuration should become immutable when the first module or script is
requested.
This prevents a module from observing one dependency value before an override
and another value afterward.

These defaults cannot remove every declaration. An offline test for code that
uses real DFHack globals or host modules must still provide fakes,
replacements, or an explicit importer. DwarfSpec should fail clearly in that
case instead of installing a large, incomplete fake DFHack runtime.

Factories, scopes, tokens, constructor injection, multi-providers, and
automatic mocks should not be in the initial contract. A test can construct a
fake table before creating the bed. Factory support should be added only if
real consumer tests demonstrate a need that ordinary Lua construction cannot
meet.

## Installed-rock downstream consumer contract

The supported downstream boundary must be the installed DwarfSpec rock, not a
DwarfSpec source checkout, sibling repository, copied loader file, or
consumer-specific package-path workaround.

The installed rock must expose the framework-neutral entry point directly:

```lua
local TestBed = require('dwarfspec.testbed')
```

`dwarfspec.testbed` and every internal resolver or environment module it needs
must be production modules beneath `src/dwarfspec/` and must be present in the
built rock. The current builtin LuaRocks layout automatically discovers Lua
modules beneath `src/`, but the release audit must still require the exact
TestBed files in the archive instead of treating autodiscovery as proof.

The installed artifact must also expose the canonical
`dwarfspec.TestBedConfig` and `dwarfspec.TestBed` annotations. The TestBed
production module is the authority for its configuration and instance types;
the shipped `ds.d.lua` declaration references the configuration type from every
`ds.mount` overload. Release checks must fail if either declaration surface is
absent from the rock or disagrees with the runtime validator.

Requiring `dwarfspec.testbed` in a normal Lua process must not:

- read or require `df`, `dfhack`, `gui`, or another DFHack-only module;
- require a running Dwarf Fortress or `dfhack-run`;
- depend on DwarfSpec's live host, scheduler, mount context, or `ds` object;
- install Busted hooks or require Busted globals;
- mutate process `package.path` or `package.preload`, or mutate unrelated
  entries in `package.loaded`; normal `package.loaded` entries created by Lua's
  `require` for `dwarfspec.testbed` and its implementation modules are allowed;
  or
- derive any path from the DwarfSpec checkout layout.

The core must support the Lua version declared by the rock, currently Lua 5.3
or newer. It may be used from Busted, but it must remain an ordinary pure-Lua
library. Standalone callers may release its graph explicitly with
`bed:close()`, while the live mount adapter owns that lifecycle automatically.

A downstream offline project should be able to install DwarfSpec into the same
LuaRocks tree used by its Lua interpreter and Busted runner, then execute:

```powershell
luarocks install dwarfspec
busted tests/unit
```

Custom LuaRocks trees may require their normal `luarocks path` environment
setup. They must not require a DwarfSpec-specific source path.

Relative roots and source mappings are resolved beneath the effective consumer
root. For framework-neutral `TestBed.new()`, that root is the process's current
directory. The contract is therefore to start Busted from the consumer project
root. For a TestBed-backed `ds.mount`, DwarfSpec supplies the active consumer
project root. TestBed does not independently discover a project root or accept
one through configuration.

For a TestBed-backed live mount, `ds.mount` creates the TestBed through
DwarfSpec's normal source-or-installed module-loading behavior. Its adapter
supplies and validates the active consumer-project root, adds the DFHack base
environment and permitted host module importer, and registers cleanup. TestBed
has no special source-versus-installed loading rule distinct from the rest of
DwarfSpec.

Consumer production modules, fakes, fixtures, and specs remain in the consumer
project. They are resolved from that project's declared roots and are never
copied into the DwarfSpec rock.

The installed-rock contract is not complete until release verification proves
both downstream paths from the generated artifact:

1. Install the rock into an empty LuaRocks tree and run a separate consumer
   fixture's offline Busted suite with no DFHack globals and no DwarfSpec
   checkout path. The fixture must load both an ordinary `require`/`mkmodule`
   graph and an annotated `reqscript` graph.
2. Use the same generated rock for a live DFHack consumer fixture that calls
   ordinary class and instance `ds.mount` forms without creating a TestBed,
   exercises TestBed-backed forms with explicit configuration, exercises
   source-backed forms with default and explicit configuration, loads
   production-style module and script dependencies from the consumer root,
   interacts with the mounted component, and finishes with confirmed cleanup.

A downstream authoring fixture must load the installed declarations and prove
that valid TestBed fields receive completion and type checking, invalid field
types are rejected, and each `ds.mount` overload accepts an optional
`dwarfspec.TestBedConfig`.

The archive audit must require the public TestBed module and its production
internals plus the public declarations while continuing to reject DwarfSpec's
own tests. Publication is blocked if the offline installed-rock proof, live
installed-rock proof, authoring-type proof, Lua 5.3 compatibility check, or
archive audit fails.

### Standalone unit-test usage

The TestBed core must not require DFHack or Busted:

```lua
describe('controller', function()
    local bed

    before_each(function()
        bed = TestBed.new{
            modules={
                ['my_plugin.clock']={
                    now=function() return 42 end,
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
idempotent, clear bed-owned references, and make later operations fail. It
should be recommended for deterministic reference release, but an unclosed
standalone bed must not leave TestBed-owned global hooks or loader mutations
behind. A test that creates a bed entirely inside one `it` block can therefore
omit explicit close when it does not need deterministic release. This does not
clean up global or native side effects performed by the consumer module itself.

### Live component-test usage

Every `ds.mount` form should accept a `dwarfspec.TestBedConfig` as its optional
final argument. Supplying it makes `ds.mount` create and own one fresh TestBed
instance:

```lua
it('renders the stored value', function()
    ---@type dwarfspec.TestBedConfig
    local testbed = {
        modules={
            ['my_plugin.storage']={
                read=function() return 'test value' end,
            },
        },
    }

    ds.mount({
        module='my_plugin.save_panel',
        export='SavePanel',
    }, {
        title='Saved value',
    }, testbed)

    assert.equals('test value', ds.get('status'):text())
end)
```

The created bed is private to the mount. On unmount or example cleanup,
DwarfSpec unmounts the component before closing the bed. Callers that need to
construct, reuse, or inspect a TestBed instance directly do so only through the
standalone `TestBed.new(config)` API; instantiated beds are not valid mount
arguments.

An ordinary class or instance mount with no final TestBed configuration uses
the existing mount implementation and creates no TestBed. A module- or
script-source mount is inherently TestBed-backed: when its final configuration
is omitted, DwarfSpec creates the required bed from the fixed defaults. This
keeps existing calls free of unused TestBed lifecycle work while retaining a
concise conventional source-backed form.

If configuration validation, bed creation, construction, or mounting fails,
`ds.mount` must immediately unwind every resource it created before reporting
the failure. The returned value remains the mounted root subject; the bed does
not replace the ordinary component-test interaction API.

A source-backed overload resolves `module` with bed-local `require` or
`script` with bed-local `reqscript`, then selects the optional exact `export`.
When `export` is omitted, the loaded value must itself be a supported component
class. This is the overload that allows configuration passed directly to
`ds.mount` to affect the component's own module graph.

There is one unavoidable semantic limit. Supplying configuration alongside an
already-loaded class or instance cannot retroactively reload its defining
module or change dependencies that its closures already captured. The
overload is still valid, but its isolation guarantee covers only work resolved
through the supplied bed. Tests that need the component's own module graph to
observe replacements should use a module- or script-source overload, as in the
examples above.

This limitation must be visible in API documentation and diagnostics. The API
must not imply that merely attaching configuration to an already-loaded class
rewrites Lua module history.

## Required module semantics

### Bed-local `require`

Every source module must execute with a `require` closure owned by its bed.
Nested imports therefore remain in the same module graph.

Each bed should have its own equivalents of:

- `package.loaded`;
- a loading-state map;
- source and result records; and
- module environments created by `mkmodule`.

The process-global `package.path`, `package.loaded`, and `package.preload` must
remain unchanged. A small bed-local `package` facade can expose `config`,
`loaded`, `path`, and `searchpath` when compatible consumer code needs them. It
must not expose `preload` or host searchers that bypass TestBed resolution.
Loader factories and bed-local preload registration are outside the initial
contract; exact in-memory replacements use `modules` instead.

Two calls for the same name in one bed must return the same identity. Two beds
loading the same pure-Lua source must produce distinct module tables, classes,
closures, and module-local state.

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
different environment in another bed.

The environment chain should be:

```text
module writes -> module environment
module reads  -> TestBed base environment -> configured runtime base
```

The environment should contain bed-local `require`, `mkmodule`, `_G`, and a
restricted `package` facade. `_G` must refer to the bed base rather than the
process global table. Direct global assignments then stay in the module or bed
instead of leaking to the interpreter.

Standalone beds should use a curated base containing the standard Lua
functions and libraries plus configured `globals`; they should not read
arbitrary process `_G` values as a fallback. The TestBed-backed `ds.mount`
adapter can add a read-through layer for `dfhack.BASE_G`, which is DFHack's
documented base for module and script environments. Mutable library tables and
values obtained through that layer remain borrowed state.

Configured `globals` are shallow-copied into the bed base and can replace
ordinary runtime-base values, including `df`, constants, and test-specific
facades. They must not replace loader-owned `_G`, `require`, `reqscript`,
`mkmodule`, `package`, `load`, `loadfile`, `dofile`, or script-owned
`dfhack_flags`. A configured `dfhack` table is a delegated facade: TestBed must
wrap it rather than expose it directly so `dfhack.reqscript` remains bed-local.
Tables supplied through `globals` are borrowed mutable state and are not reset
by `bed:close()`.

Bed-local `load`, `loadfile`, and `dofile` behavior must not silently execute a
chunk in process `_G`. They should either preserve the current bed environment
and allowed-root checks or fail with a clear unsupported-operation error.

This is compatibility isolation, not a security boundary. The `debug` library,
borrowed mutable tables, userdata, and native functions can still escape or
mutate state.

### Host module imports

Live components need real DFHack modules such as `class`, `gui`, and
`gui.widgets`. A TestBed-backed `ds.mount` should make the small documented
component profile available by default so the usual component test does not
repeat that boilerplate. Every other host module should be borrowed only
through an exact name supplied in `imports`.

The component-import set is part of DwarfSpec's public compatibility contract.
It must be versioned, tested, and reported in bed diagnostics. It is not
permission to fall back to arbitrary host `require`. Framework-neutral
`TestBed.new()` has no live importer or default host imports.

A borrowed module is shared host state:

- TestBed does not reload or unload it;
- its own nested dependencies were resolved by the host, not by the bed;
- its mutations are not reversed by `bed:close()`; and
- replacing a dependency in the bed cannot retroactively alter a borrowed
  module that already captured the host dependency.

This bounded default plus explicit boundary is preferable to silently falling
back to host `require`, which would make a missing test declaration pass in
live DFHack and fail in standalone Lua.

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

Faithful TestBed support for this script-module form is required in the first
usable contract. It must use a separate operation and cache:

```lua
local bed = TestBed.new()
local script = bed:reqscript('internal/my_plugin/worker')
```

Its configuration should use separate `script_roots`, `scripts`, and
`script_sources` fields only when the conventional script root or real script
implementation is unsuitable for the test. A script environment must be
allocated before the script executes so supported circular script imports can
observe the same partially initialized environment. It must validate the
module annotation and run with `dfhack_flags.module == true`.

Every TestBed-loaded module and script environment must receive the bed-local
`reqscript` function so production code can use the ordinary unqualified form.
The `dfhack` value visible inside the bed must also expose the same bed-local
operation as `dfhack.reqscript` without modifying the borrowed process-global
`dfhack` table. Other `dfhack` fields may delegate through the configured or
live DFHack facade.

Bed-local script resolution must be deterministic:

1. return the script environment already cached by this bed;
2. use an exact environment replacement from `scripts`;
3. use an exact source mapping from `script_sources`;
4. search `script_roots` in declared order; or
5. fail with the complete script dependency chain.

TestBed must not silently fall back to the process-global DFHack `reqscript`.
That would reintroduce shared script caches and make an undeclared dependency
pass live while failing offline. A test can declare a replacement or source
root for every script dependency it needs.

TestBed emulates DFHack's import-facing script semantics; it does not claim to
reproduce live script-path integration, mod activation, save-specific path
changes, or file-change hot reload. Tests for those behaviors must call the
real DFHack `reqscript` outside TestBed. Keeping the module and script
namespaces separate preserves their different return, environment, cache, and
cycle contracts.

## Isolation guarantees

The public documentation should use precise levels instead of the unqualified
word "isolated".

| Boundary | TestBed guarantee |
|---|---|
| Module cache | Private to one bed. |
| Pure-Lua module state | Fresh when source is loaded by a fresh bed. |
| Dependency replacement | Exact and local to the bed graph. |
| Direct global writes | Retained in bed-owned environments. |
| Host `package` tables | Not modified. |
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
live ds.mount(..., testbed) -> mount adapter --------/
                                |                     |
                                +-> component mount   +-> optional host imports
                                                      +-> source files
```

`dwarfspec.testbed` should own configuration validation, caching, loading,
dependency-chain diagnostics, reset, and close behavior. Small internal
resolver and environment modules are justified if they keep path validation
and Lua-environment construction independently testable.

The live mount adapter should:

- validate the final `dwarfspec.TestBedConfig` independently from existing
  component and mount options;
- create one fresh bed when configuration is supplied;
- create one fresh bed from the fixed defaults when a module- or script-source
  form omits configuration;
- leave ordinary class and instance mounts TestBed-free when configuration is
  omitted;
- provide the DFHack base environment and host importer;
- constrain paths to the active consumer project;
- resolve a module or script source through the bed when that overload is used;
- otherwise pass the original class or instance unchanged;
- pass the existing component options to the component-mount boundary
  unchanged;
- coordinate mount-before-bed cleanup order;
- attach bed state to run diagnostics; and
- verify that no active bed remains at example and run cleanup.

It should not contain the loader algorithm or a second component-mount
implementation. This allows the same graph behavior to be tested quickly under
standalone Lua 5.4 and compatibility-compiled under Lua 5.3.

All module names and source paths must be validated. Resolved files must remain
beneath their declared roots after separator normalization and current- or
parent-directory collapse. Error messages should include the requested module,
the resolution attempts, and the dependency chain without dumping unbounded
tables or source.

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
| The API promises more isolation than it provides. | Publish the isolation table above and expose borrowed modules in diagnostics. |
| Live and standalone defaults hide an accidental portability difference. | Use one core loader, keep the component-import set small and exact, and report every borrowed host import. |
| A conventional default root selects an unintended duplicate module. | Use a fixed documented precedence, report the selected source, and allow explicit roots to replace the convention. |
| The runner starts outside the consumer project. | Fail with the effective current directory and attempted roots; require standalone Busted to start at the consumer project root. |
| A module escapes through global `require`, `package`, `loadfile`, or `_G`. | Install bed-local functions and a restricted package facade in every source environment. |
| A fake silently masks a misspelled production module. | Validate names, freeze configuration, and report whether each module came from a value, source, root, or host import. |
| Circular imports return inconsistent state. | Track loading chains explicitly; support only documented semantics and fail with the complete cycle otherwise. |
| A borrowed GUI class and a bed-loaded copy have incompatible identities. | Borrow DFHack framework modules exactly and warn against loading them from source roots. |
| A test passes an already-loaded class and expects replacements to affect its captured dependencies. | Accept the overload but document its narrower boundary; require a module- or script-source overload when the component's defining graph must observe replacements. |
| A TestBed configuration table is confused with component constructor options. | Keep `dwarfspec.TestBedConfig` in a dedicated final parameter instead of inferring intent from table keys. |
| Cleanup releases the graph while a mounted object still references it. | Register bed cleanup before mount cleanup and drain in LIFO order. |
| Tests become tied to TestBed instead of improving production seams. | Keep the API loader-oriented and avoid injection tokens or constructor rewriting. |
| Path lookup can escape the consumer project. | Canonicalize and contain every resolved source beneath an allowed root. |
| `reqscript` fidelity becomes accidental and incomplete. | Implement it as a separate resolver with annotation, flags, environment, cache, and cycle tests. |

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

This would require production modules to adopt tokens, provider factories, or
constructor conventions that DFHack and ordinary Lua do not use. It would solve
a different problem and create substantial framework coupling.

### Use only source-file environment injection

Loading one file with a custom `_ENV` is insufficient because nested
`require()` calls re-enter the process-global graph. Isolation must own the
transitive loader.

## Recommended delivery

The first usable increment should contain:

- zero-argument framework-neutral `TestBed.new()`;
- canonical `dwarfspec.TestBedConfig` and `dwarfspec.TestBed` authoring types in
  the installed rock;
- `TestBed.new(config)` annotated and runtime-validated against that canonical
  configuration type;
- the optional final `dwarfspec.TestBedConfig` parameter on every `ds.mount`
  overload;
- typed module- and script-source mount overloads that resolve the component
  through the mount-created bed;
- no TestBed allocation or lifecycle change for existing class and instance
  mounts that omit TestBed configuration;
- mount ownership of one fresh TestBed when configuration is supplied or a
  source-backed form requires default TestBed resolution;
- the fixed project-layout defaults and documented live component-import set;
- optional `module_roots`, `sources`, `modules`, `globals`, exact `imports`, and
  `component_imports=false` for disabling default host imports on a mount;
- optional `script_roots`, `script_sources`, and exact `scripts`;
- bed-local `require`, cache, environment, `_G`, restricted `package` without
  preload registration, and `mkmodule`;
- bed-local `reqscript` and `dfhack.reqscript`, with annotation validation,
  `dfhack_flags.module`, a separate script cache, and supported circular script
  imports;
- immutable configuration after first load;
- idempotent `close`;
- module and script dependency-chain plus resolution-source diagnostics;
- standalone unit coverage on Lua 5.4;
- Lua 5.3 syntax compatibility;
- atomic `ds.mount` TestBed cleanup integration with focused default- and
  explicit-configuration live component proofs;
- required TestBed files in the generated rock archive;
- an offline downstream Busted proof from an empty installed-rock tree; and
- a live downstream component proof using the same generated rock.

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
- `TestBed.new(config)` exposes completion and type checking for every
  `dwarfspec.TestBedConfig` field from the installed rock;
- every `ds.mount` overload exposes the same optional final
  `dwarfspec.TestBedConfig` parameter;
- existing class and instance mount calls that omit TestBed configuration do
  not create a bed and retain their existing behavior;
- each mount overload that receives TestBed configuration creates one fresh
  bed from it and closes that bed automatically;
- module- and script-source overloads create one fresh bed from the fixed
  defaults when configuration is omitted and close it automatically;
- module- and script-source overloads resolve the component itself through the
  mount-created bed, so replacements affect its defining graph;
- existing two-argument mount calls remain source- and behavior-compatible;
- component constructor options and TestBed configuration remain unambiguous
  even when they contain identical field names;
- every configuration field can be omitted independently, explicit root lists
  replace their defaults, exact imports remain additive, and the component
  import set can be disabled deterministically;
- explicit `modules` and `sources` can replace enabled host imports, while an
  enabled exact host import takes precedence over an accidental file with the
  same module name in a consumer root;
- configured globals replace ordinary runtime-base values, reserved
  loader-owned names are rejected, and a configured `dfhack` facade retains
  bed-local `dfhack.reqscript`;
- `require('dwarfspec.testbed')` succeeds from an installed rock without
  DFHack globals or a DwarfSpec checkout on the Lua path;
- loading the framework-neutral TestBed module does not load the live host,
  scheduler, mount, `ds`, or Busted integration modules;
- the generated rock contains every public and internal TestBed production
  module and no DwarfSpec tests;
- two beds load the same stateful source without sharing module state;
- nested dependencies use the same bed and observe exact replacements;
- bed-local loading leaves process `package.path` and `package.preload`
  unchanged and does not change unrelated `package.loaded` entries beyond the
  normal cache entries created when requiring TestBed itself;
- the bed-local `package` facade does not expose nonfunctional preload
  registration;
- `mkmodule` returns stable state within one bed and fresh state across beds;
- `bed:reqscript` and TestBed-local `dfhack.reqscript` return the same
  bed-owned script environment for one script name;
- annotated scripts observe `dfhack_flags.module == true` and command-only side
  effects below their module guard do not run;
- missing `--@ module=true` declarations fail before script execution;
- supported circular script imports share their preallocated environments
  without entering the process-global script cache;
- two beds load the same script source without sharing script globals;
- direct module global writes do not reach process `_G`;
- missing modules, missing scripts, and dependency cycles produce bounded,
  actionable chains;
- a live host module outside the documented component-import set fails unless
  explicitly listed in `imports`;
- exact host imports preserve the real DFHack class identities needed by
  `ds.mount`;
- supplying TestBed configuration for an already-loaded class reports the
  narrower isolation boundary and does not claim that captured dependencies
  were replaced;
- a source-backed component loaded through a mount-created bed observes the
  replacements in the supplied TestBed configuration;
- a separate downstream fixture runs offline Busted tests against the installed
  rock and consumer-owned production modules plus annotated script modules;
- a production-style widget from that downstream fixture is loaded through a
  TestBed configuration with both module and script dependencies, then mounts
  and interacts in live DFHack using the same rock;
- bed creation, construction, mount, and assertion failures still close every
  mount-owned bed, with component
  teardown preceding bed teardown whenever construction reached a mounted
  component;
- consecutive live examples see fresh consumer module state; and
- final cleanup verification reports no active beds without treating that as
  proof that native or gameplay side effects were reversed.

The prototype should be evaluated against at least one real consumer module,
not only synthetic fixtures. The main success measure is reduced setup and
cleanup code while retaining clear dependency and ownership boundaries.

## Verdict

The proposed system has a favorable usefulness-to-complexity ratio if it stays
focused on module-graph ownership.

It should be described as "an isolated Lua module environment for tests," with
the isolation level qualified. It should not be described as a complete
sandbox or as a mechanism that makes live DFHack behavior portable to
standalone Lua.

The best design is an instance-scoped, strict, deterministic loader shared by
standalone and live tests. Standalone tests create the instance directly;
component tests pass the same strongly typed configuration as the optional
final argument to any `ds.mount` overload when they need TestBed-backed
composition. Source-backed mounts create a bed even when configuration is
omitted because source resolution requires it. Existing class and instance
mounts create no TestBed when the final argument is omitted. Whenever a mount
creates a TestBed, DwarfSpec owns that instance and its cleanup. That design
provides controlled composition and fresh per-test state without imposing an
unused loader lifecycle on ordinary mounts.

## References

- [DFHack Lua module and script API](https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html)
- [DFHack modding guide](https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html)
