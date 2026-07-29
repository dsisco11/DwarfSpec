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

- declare the environment before loading the subject;
- prefer real dependencies unless a test explicitly replaces one;
- freeze configuration after the first load;
- create fresh state for each example; and
- make teardown deterministic.

Ordinary Lua modules obtain dependencies through `require`, globals, and
captured values. A static TestBed API would add another global mutable registry
on top of `package.loaded`, which is the state the feature is intended to
avoid.

DwarfSpec should therefore expose ordinary TestBed instances.

## Recommended public contract

The framework-neutral entry point should be:

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new{
    module_roots={'src'},
    modules={
        ['my_plugin.clock']=fake_clock,
        ['my_plugin.storage']=fake_storage,
    },
    globals={
        df=fake_df,
        dfhack=fake_dfhack,
    },
}

local controller = bed:require('my_plugin.controller')
```

The minimum configuration fields should be:

| Field | Meaning |
|---|---|
| `module_roots` | Ordered roots used for `name.lua` and `name/init.lua` lookup. |
| `modules` | Exact module-name to module-value replacements. |
| `sources` | Optional exact module-name to source-file mappings. |
| `globals` | Values added to the bed's base global environment. |
| `imports` | Exact module names that may be borrowed from the host loader. |

Resolution should be deterministic:

1. return a value already cached by this bed;
2. use an exact value from `modules`;
3. use an exact file mapping from `sources`;
4. search `module_roots` in declared order;
5. borrow an exact name listed in `imports`; or
6. fail with the complete dependency chain.

Configuration should become immutable when the first module is requested.
This prevents a module from observing one dependency value before an override
and another value afterward.

Factories, scopes, tokens, constructor injection, multi-providers, and
automatic mocks should not be in the initial contract. A test can construct a
fake table before creating the bed. Factory support should be added only if
real consumer tests demonstrate a need that ordinary Lua construction cannot
meet.

### Standalone unit-test usage

The TestBed core must not require DFHack or Busted:

```lua
describe('controller', function()
    local bed

    before_each(function()
        bed = TestBed.new{
            module_roots={'src'},
            modules={
                ['my_plugin.clock']={
                    now=function() return 42 end,
                },
            },
            globals={
                df={global={}},
                dfhack={},
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
idempotent, clear bed-owned references, and make later operations fail.

### Live component-test usage

The run-scoped `ds` object should provide a convenience constructor:

```lua
it('renders the stored value', function()
    local bed = ds.testBed{
        module_roots={'src'},
        modules={
            ['my_plugin.storage']={
                read=function() return 'test value' end,
            },
        },
        imports={'class', 'gui', 'gui.widgets'},
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
`gui.widgets`. These should be borrowed only through the exact `imports`
allowlist.

A borrowed module is shared host state:

- TestBed does not reload or unload it;
- its own nested dependencies were resolved by the host, not by the bed;
- its mutations are not reversed by `bed:close()`; and
- replacing a dependency in the bed cannot retroactively alter a borrowed
  module that already captured the host dependency.

This explicit boundary is preferable to silently falling back to host
`require`, which would make a missing test declaration pass in live DFHack and
fail in standalone Lua.

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

The architecture should reserve a separate operation and cache:

```lua
local script = bed:reqscript('internal/my_plugin/worker')
```

Its configuration should use separate `script_roots`, `scripts`, and
`script_sources` fields. A script environment must be allocated before the
script executes so supported circular script imports can observe the same
partially initialized environment. It must validate the module annotation and
run with `dfhack_flags.module == true`.

This support is important for mod code, but it is a distinct implementation
increment after `require` and `mkmodule`. Keeping the namespaces separate
avoids false fidelity to DFHack's script-path precedence and reload behavior.

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
| Live and standalone resolution behave differently. | Use one core loader and require exact host imports. |
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

- framework-neutral `TestBed.new`;
- `module_roots`, `sources`, `modules`, `globals`, and exact `imports`;
- bed-local `require`, cache, environment, `_G`, `package`, and `mkmodule`;
- immutable configuration after first load;
- idempotent `close`;
- dependency-chain and resolution-source diagnostics;
- standalone unit coverage on Lua 5.4;
- Lua 5.3 syntax compatibility; and
- `ds.testBed` cleanup integration with one focused live component proof.

The next increment should add faithful `reqscript` support with its separate
script namespace. Reload APIs, factories, convenience Busted adapters, and
diagnostic graph inspection should be considered only after representative
consumer tests establish a need.

The existing run-level project path and eviction logic should remain in place
throughout. It supports ordinary specs and loads the spec files themselves;
TestBed is a narrower per-example composition tool.

## Prototype acceptance criteria

A prototype is successful only if it demonstrates all of the following:

- two beds load the same stateful source without sharing module state;
- nested dependencies use the same bed and observe exact replacements;
- process `package.path`, `package.loaded`, and `package.preload` are unchanged;
- `mkmodule` returns stable state within one bed and fresh state across beds;
- direct module global writes do not reach process `_G`;
- missing modules and dependency cycles produce bounded, actionable chains;
- undeclared host fallback fails;
- exact host imports preserve the real DFHack class identities needed by
  `ds.mount`;
- a production-style widget loaded by a bed mounts and interacts in live
  DFHack;
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
