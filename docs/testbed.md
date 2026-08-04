# TestBed module and script graphs

TestBed gives one test a private Lua module cache, annotated-script cache, and
source-loading environment. It is useful when production code already loads
replaceable collaborators through `require`, `mkmodule`, or
`dfhack.reqscript`.

TestBed is not a security sandbox. It does not undo writes through borrowed
tables, native functions, DF globals or userdata, timers, hooks, files,
screens, plugins, or game actions. DwarfSpec's normal live mount cleanup remains
responsible for UI and run-owned resources.

## Standalone use

Run standalone tests from the consumer project root. With the conventional
layout, no configuration is needed:

```text
src/
  controller.lua
  scripts_modinstalled/
    state.lua
```

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new()
local controller = bed:require('controller')
local state = bed:reqscript('state')

bed:close()
```

The default module roots, in precedence order, are
`src/scripts_modinstalled`, `src`, and `.`. The default script root is
`src/scripts_modinstalled`. Missing default directories are skipped. An
explicit `module_roots` or `script_roots` array replaces its complete default;
relative roots and `use_source` paths resolve from the process working
directory. This is a resolution convention, not a filesystem-containment
boundary.

Use `close()` for deterministic release. It is idempotent. After close,
`require`, `reqscript`, and retained TestBed-owned loader closures fail with the
same closed-state error. Values already returned to the caller remain ordinary
Lua references and continue to work unless they call a retained loader. An
unclosed standalone bed installs no process-global hook, but it also cannot
undo effects performed outside its owned graph.

The supported consumer API is `TestBed.new(config?)`, `bed:require(name)`,
`bed:reqscript(name)`, and `bed:close()`. `TestBed.is_instance(value)` is an
identity predicate used by DwarfSpec's mount validator; it does not expose graph
state. Reload and diagnostic graph-inspection APIs are intentionally deferred.

## Configure dependencies

Configuration can replace both ordinary modules and annotated scripts before
the consumer source is loaded:

```lua
local fake_clock = {now=function() return 42 end}
local fake_state = {read=function() return 'ready' end}

local bed = TestBed.new{
    module_roots={'src'},
    script_roots={'src/scripts_modinstalled'},
    globals={BUILD_MODE='test'},
    imports={
        {
            provide={kind='module', name='my_plugin.clock'},
            use_value=fake_clock,
        },
        {
            provide={kind='module', name='my_plugin.clock_alias'},
            use_existing={kind='module', name='my_plugin.clock'},
        },
        {
            provide={kind='module', name='my_plugin.file_store'},
            use_source='tests/fixtures/file_store.lua',
        },
        {
            provide={kind='script', name='my_plugin/state'},
            use_value=fake_state,
        },
    },
}
```

Each `provide` token is the exact pair `(kind, name)`. Module and script tokens
with the same name are different dependencies. A provider selects exactly one
strategy:

| Strategy | Behavior |
|---|---|
| `use_value` | Returns the exact non-`nil` borrowed value. Script values must be tables. `false` is a valid module value. |
| `use_source` | Loads one explicit source file inside the bed. Relative paths use the effective consumer root. |
| `use_host=true` | Borrows the exact module or script from the live host. It is rejected for standalone beds. |
| `use_existing` | Aliases another exact token in the same namespace and returns its identity. |

Providers take precedence over matching source files. Duplicate user tokens are
errors. On live mounts, a user provider replaces a synthesized provider with
the same token. The module token `dfhack` is reserved for the TestBed facade and
cannot be provided by any strategy.

`globals` adds or replaces ordinary base-environment bindings. Nested values
are borrowed. `globals.dfhack`, when present, is the complete ordinary API
behind the bed's `dfhack` facade; missing members do not fall through to live
DFHack. Loader-owned global names cannot be configured.

`component_imports` defaults to `false` for standalone beds and `true` for live
descriptor mounts. Setting it to `false` on a live mount disables all
synthesized component imports. Explicitly enabling it in a standalone bed is
rejected because no live host importer exists.

## Mount a live component from its defining graph

Tagged descriptors make component resolution and construction occur inside a
fresh, mount-owned TestBed:

```lua
---@type dwarfspec.TestBedConfig
local testbed = {
    imports={
        {
            provide={kind='module', name='my_plugin.storage'},
            use_value={read=function() return 'test value' end},
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

The second argument is passed unchanged to the component constructor. The
optional third argument is only the TestBed configuration. Identically named
fields in those tables do not cross between them. A script descriptor has the
same shape with `kind='script'` and resolves through `reqscript`:

```lua
ds.mount({kind='script', name='my_plugin/panel', export='Panel'}, nil, {
    imports={
        {
            provide={kind='script', name='my_plugin/state'},
            use_value={status='ready'},
        },
    },
})
```

Omitting the third argument still creates a TestBed using the fixed live
defaults. Omitting `export` requires the loaded value itself to be a supported
component class. Descriptor names are logical names; callers do not supply a
component file path.

Ordinary class mounts retain their two-argument form and allocate no TestBed.
They do not accept TestBed configuration. Already-created component instances
are rejected because DwarfSpec cannot own their construction. On cleanup,
DwarfSpec unmounts and destroys the component before closing its bed. Any
failure after bed allocation unwinds the resources created up to that point.

### Versioned live imports and loader policy

The live compatibility policy currently targets DFHack `53.15-r2`. Its
synthesized module tokens are exactly `class`, `utils`, `gui`, `gui.widgets`,
and `gui.dwarfmode`. These are borrowed host modules so components retain the
real DFHack class identities. A live host module outside that set must be
declared explicitly with `use_host=true`.

Do not load foundational DFHack framework modules from TestBed source roots:
the resulting Lua classes have different identities from the host's classes.
Use the synthesized providers or explicit host providers instead. Borrowed host
modules also retain whatever nested dependencies the host resolved for them;
TestBed-local providers cannot retroactively replace that host-owned graph.

For the same reason, do not load one consumer source both with process-global
`require` and through a TestBed in the same example when class or singleton
identity matters. The two loader graphs intentionally create different
identities.

For this supported DFHack version, TestBed owns or rejects these loader entry
points rather than allowing them to fall through to the host:

| Facade | Protected entries |
|---|---|
| Base environment and `dfhack.BASE_G` | `_G`, `package`, `require`, `reqscript`, `mkmodule`, `load`, `loadfile`, `dofile`, `reload`, `script_environment`, `dfhack_flags`, `dfhack` |
| `dfhack` | `BASE_G`, `reqscript`, `reload`, `script_environment` |

`reload`, `dfhack.reload`, `script_environment`, and
`dfhack.script_environment` fail as unsupported. The bound `require`,
`reqscript`, `mkmodule`, `load`, `loadfile`, and `dofile` operations remain
inside their owning bed. Normal assignment and the bed-local `rawset` wrapper
reject replacement of protected fields.

## Lua and package behavior

Every bed has an authoritative private `package.loaded`, `package.preload`,
`package.searchers`, and `package.path`. Ordinary entry mutations and searcher
or path replacement affect later non-reserved loads in that bed. Replacing the
exposed `package.loaded` or `package.preload` table reference does not replace
the internal table used by the loader. Native `package.cpath` loading and
`package.loadlib` are unavailable.

Module cache and return behavior follows the running Lua interpreter. In
particular, a cached `false` value does not suppress a later load; a `nil`
return preserves an explicitly published `package.loaded[name]` value or stores
`true`; and an explicit loader return replaces a published value. Lua 5.4 can
return a second loader-data result on the initial load, while Lua 5.3 returns
only the module value. Cache hits have no loader-data result. The standalone
conformance suite runs on Lua 5.4; Lua 5.3 is supported without a dedicated
conformance suite.

`mkmodule(name)` immediately publishes its module environment, so a circular
import can observe explicitly published partial state. A cycle that has not
published a non-`nil`, non-`false` cache value fails with a bounded dependency
chain instead of recursing without limit. Annotated script cycles use
preallocated script environments. Alias-only cycles fail with a similarly
bounded chain. Failed loads clear active markers and uncommitted preallocated
state so a later call can retry.

Each source module receives a module-local `_G`; direct global writes remain in
that environment. `dfhack.BASE_G` is the stable bed-wide facade for deliberate
shared writes. The initial global `dfhack` and `require('dfhack')` are the same
facade. A live bed snapshots non-reserved raw host-base bindings when it is
constructed. Standalone beds copy only the documented standard Lua bindings.

Source-loaded scripts must declare `--@ module=true`. They receive their own
raw `dfhack_flags` table with `module=true`. The legacy `moduleMode` convention
is not supported.

## Isolation boundaries and explicit escapes

| Boundary | Guarantee |
|---|---|
| Bed-owned module and script caches | Private to one bed. |
| Pure-Lua source state | Fresh when loaded by a fresh bed. |
| Dependency replacement | Exact and local to the bed graph. |
| Direct source globals | Retained in bed-owned environments. |
| Host `package` tables | Not modified by TestBed-owned loaders; host providers may populate host caches. |
| Borrowed module or standard-library tables | Shared and not restored. |
| DF globals, userdata, and native functions | Shared when supplied and not restored. |
| Timers, hooks, files, screens, plugins, and game effects | Not automatically reversed by the loader. |
| Malicious or unrestricted Lua | Not securely sandboxed. |

The `debug` library, borrowed native functions, externally supplied
`package.preload` functions, and replacement searchers can deliberately leave
the rewritten environment. They are escape hatches, not isolation guarantees.
Use a separate Lua process for untrusted or highly stateful code.
