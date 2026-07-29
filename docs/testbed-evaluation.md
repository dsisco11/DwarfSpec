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

- make the conventional case work with `TestBed.new()` or `ds.testBed()`;
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

DwarfSpec should therefore expose ordinary TestBed instances.

## Recommended public contract

The framework-neutral zero-configuration path should be:

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new()
local controller = bed:require('my_plugin.controller')
```

The equivalent live component path should be:

```lua
local bed = ds.testBed()
local SavePanel = bed:require('my_plugin.save_panel')
```

Both constructors must accept a missing configuration table. Configuration is
progressive: users should provide only values that differ from the defaults.
For example, a unit test replacing one dependency should need only:

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
| `project_root` | Current directory offline; active consumer-project root live. | Explicit base for relative roots and source files. |
| `module_roots` | `src/scripts_modinstalled`, then `src`, then `.` beneath the project root. | Replacement ordered roots for `name.lua` and `name/init.lua`. |
| `modules` | Empty. | Exact module-name to module-value replacements. |
| `sources` | Empty. | Exact module-name to source-file mappings. |
| `globals` | Curated Lua plus a minimal bed-local `dfhack.reqscript` facade offline; curated Lua plus the live DFHack facade live. | Additional or replacement globals. |
| `import_profile` | None offline; `component` under `ds.testBed()`. | Set to `false` for no default host imports. |
| `imports` | Empty. | Exact host modules added to the selected profile. |
| `script_roots` | `src/scripts_modinstalled` beneath the project root. | Replacement ordered roots searched by bed-local `reqscript`. |
| `scripts` | Empty. | Exact script-name to script-environment replacements. |
| `script_sources` | Empty. | Exact script-name to source-file mappings. |

The default roots are a fixed convention, not an open-ended directory scan.
Missing default directories are skipped. An error must list the effective
roots that were tried. Explicitly providing a root list replaces its default,
including with an empty list when a source-only bed is desired.

The initial documented live component import profile should contain only
common, foundational DFHack library modules: `class`, `utils`, `gui`,
`gui.widgets`, and `gui.dwarfmode`. It must not include registry- or
scheduler-oriented modules such as `plugins.overlay`, `plugins.eventful`,
`repeat-util`, or `script-manager`. Tests that need one of those shared host
modules must name it in `imports`. The list extends the profile so adding one
uncommon dependency does not require restating the common ones.
`import_profile=false` selects strict source-only loading; it can be combined
with `imports` to construct a fully custom exact allowlist.

Resolution should be deterministic:

1. return a value already cached by this bed;
2. use an exact value from `modules`;
3. use an exact file mapping from `sources`;
4. search `module_roots` in declared order;
5. borrow an exact name in the effective profile-plus-`imports` allowlist; or
6. fail with the complete dependency chain.

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

Requiring `dwarfspec.testbed` in a normal Lua process must not:

- read or require `df`, `dfhack`, `gui`, or another DFHack-only module;
- require a running Dwarf Fortress or `dfhack-run`;
- depend on DwarfSpec's live host, scheduler, mount context, or `ds` object;
- install Busted hooks or require Busted globals;
- mutate process `package.path`, `package.loaded`, or `package.preload`; or
- derive any path from the DwarfSpec checkout layout.

The core must support the Lua version declared by the rock, currently Lua 5.3
or newer. It may be used from Busted, but it must remain an ordinary pure-Lua
library. Standalone callers may release its graph explicitly with
`bed:close()`, while the live adapter owns that lifecycle automatically.

A downstream offline project should be able to install DwarfSpec into the same
LuaRocks tree used by its Lua interpreter and Busted runner, then execute:

```powershell
luarocks install dwarfspec
busted tests/unit
```

Custom LuaRocks trees may require their normal `luarocks path` environment
setup. They must not require a DwarfSpec-specific source path.

Relative roots and source mappings are resolved beneath `project_root`. For
framework-neutral `TestBed.new()`, `project_root` defaults to the current
directory and the conventional module and script roots are supplied
automatically. The normal contract is therefore to start Busted from the
consumer project root. A consumer need only configure `project_root` when its
runner uses another working directory, or configure roots when its layout does
not follow the convention.

In a live test, `ds.testBed()` must instantiate the exact same packaged
`dwarfspec.testbed` core. Its adapter supplies and validates the active
consumer-project root, adds the DFHack base environment and permitted host
module importer, and registers cleanup. It must not substitute a second live
implementation or load TestBed files from a source checkout.

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
   `ds.testBed()`, loads production-style module and script dependencies from
   the consumer root, mounts a component, interacts with it, and finishes with
   confirmed cleanup.

The archive audit must require the public TestBed module and its production
internals while continuing to reject DwarfSpec's own tests. Publication is
blocked if the offline installed-rock proof, live installed-rock proof, Lua
5.3 compatibility check, or archive audit fails.

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

The run-scoped `ds` object should provide a convenience constructor:

```lua
it('renders the stored value', function()
    local bed = ds.testBed{
        modules={
            ['my_plugin.storage']={
                read=function() return 'test value' end,
            },
        },
    }

    local SavePanel = bed:require('my_plugin.save_panel')
    ds.mount(SavePanel)

    assert.equals('test value', ds.get('status'):text())
end)
```

`ds.testBed()` should create the same core object and register `bed:close()` in
the current example's cleanup registry. Normal LIFO cleanup means a component
loaded from the bed and mounted afterward is unmounted before the bed releases
its module graph.

The convenience API must not make a TestBed global, change `ds.mount()`, or
allow a bed to survive its owning example.

## Required module semantics

### Bed-local `require`

Every source module must execute with a `require` closure owned by its bed.
Nested imports therefore remain in the same module graph.

Each bed should have its own equivalents of:

- `package.loaded`;
- `package.preload`;
- a loading-state map;
- source and result records; and
- module environments created by `mkmodule`.

The process-global `package.path`, `package.loaded`, and `package.preload` must
remain unchanged. A small bed-local `package` facade can expose `config`,
`loaded`, `preload`, `path`, and `searchpath` when compatible consumer code
needs them. It must not expose host searchers that bypass TestBed resolution.

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
arbitrary process `_G` values as a fallback. The live `ds.testBed()` adapter can
add a read-through layer for `dfhack.BASE_G`, which is DFHack's documented base
for module and script environments. Mutable library tables and values obtained
through that layer remain borrowed state.

Bed-local `load`, `loadfile`, and `dofile` behavior must not silently execute a
chunk in process `_G`. They should either preserve the current bed environment
and allowed-root checks or fail with a clear unsupported-operation error.

This is compatibility isolation, not a security boundary. The `debug` library,
borrowed mutable tables, userdata, and native functions can still escape or
mutate state.

### Host module imports

Live components need real DFHack modules such as `class`, `gui`, and
`gui.widgets`. `ds.testBed()` should make the small documented component
profile available by default so the usual component test does not repeat that
boilerplate. Every other host module should be borrowed only through an exact
name supplied in `imports`.

The live profile is part of DwarfSpec's public compatibility contract. It must
be versioned, tested, and reported in bed diagnostics. It is not permission to
fall back to arbitrary host `require`. Framework-neutral `TestBed.new()` has no
live importer or default host imports.

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
live ds.testBed adapter ---/                         |
                                                      +-> optional host imports
                                                      +-> source files
```

`dwarfspec.testbed` should own configuration validation, caching, loading,
dependency-chain diagnostics, reset, and close behavior. Small internal
resolver and environment modules are justified if they keep path validation
and Lua-environment construction independently testable.

The live adapter should only:

- provide the DFHack base environment and host importer;
- constrain paths to the active consumer project;
- register cleanup;
- attach bed state to run diagnostics; and
- verify that no active bed remains at example and run cleanup.

It should not contain the loader algorithm. This allows the same graph behavior
to be tested quickly under standalone Lua 5.4 and compatibility-compiled under
Lua 5.3.

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
| Live and standalone defaults hide an accidental portability difference. | Use one core loader, keep the live profile small and exact, and report every borrowed host import. |
| A conventional default root selects an unintended duplicate module. | Use a fixed documented precedence, report the selected source, and allow explicit roots to replace the convention. |
| The runner starts outside the consumer project. | Fail with the effective project root and attempted roots; support one explicit `project_root` override. |
| A module escapes through global `require`, `package`, `loadfile`, or `_G`. | Install bed-local functions and a restricted package facade in every source environment. |
| A fake silently masks a misspelled production module. | Validate names, freeze configuration, and report whether each module came from a value, source, root, or host import. |
| Circular imports return inconsistent state. | Track loading chains explicitly; support only documented semantics and fail with the complete cycle otherwise. |
| A borrowed GUI class and a bed-loaded copy have incompatible identities. | Borrow DFHack framework modules exactly and warn against loading them from source roots. |
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

- zero-argument framework-neutral `TestBed.new()` and live `ds.testBed()`;
- the fixed project-layout defaults and documented live component import
  profile;
- optional `project_root`, `module_roots`, `sources`, `modules`, `globals`, and
  exact `imports`, plus `import_profile=false` for strict host loading;
- optional `script_roots`, `script_sources`, and exact `scripts`;
- bed-local `require`, cache, environment, `_G`, `package`, and `mkmodule`;
- bed-local `reqscript` and `dfhack.reqscript`, with annotation validation,
  `dfhack_flags.module`, a separate script cache, and supported circular script
  imports;
- immutable configuration after first load;
- idempotent `close`;
- module and script dependency-chain plus resolution-source diagnostics;
- standalone unit coverage on Lua 5.4;
- Lua 5.3 syntax compatibility;
- `ds.testBed` cleanup integration with one focused live component proof;
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
- `ds.testBed()` loads and mounts a conventional component without a
  configuration table;
- every configuration field can be omitted independently, explicit root lists
  replace their defaults, imports extend the selected profile, and the profile
  can be disabled deterministically;
- `require('dwarfspec.testbed')` succeeds from an installed rock without
  DFHack globals or a DwarfSpec checkout on the Lua path;
- loading the framework-neutral TestBed module does not load the live host,
  scheduler, mount, `ds`, or Busted integration modules;
- the generated rock contains every public and internal TestBed production
  module and no DwarfSpec tests;
- two beds load the same stateful source without sharing module state;
- nested dependencies use the same bed and observe exact replacements;
- process `package.path`, `package.loaded`, and `package.preload` are unchanged;
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
- a live host module outside the documented profile fails unless explicitly
  listed in `imports`;
- exact host imports preserve the real DFHack class identities needed by
  `ds.mount`;
- a separate downstream fixture runs offline Busted tests against the installed
  rock and consumer-owned production modules plus annotated script modules;
- a production-style widget from that downstream fixture is loaded through
  `ds.testBed` with both module and script dependencies, mounts, and interacts
  in live DFHack using the same rock;
- assertion failure still closes the bed after unmounting the component;
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
standalone and live tests, plus a thin DwarfSpec lifecycle adapter. That design
provides controlled composition and fresh per-test state while preserving
ordinary Lua module and DwarfSpec lifecycle boundaries.

## References

- [DFHack Lua module and script API](https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html)
- [DFHack modding guide](https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html)
