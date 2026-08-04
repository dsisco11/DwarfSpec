# Testing modules and scripts with TestBed

TestBed loads Lua modules and DFHack annotated scripts in a private dependency
graph. Use it when you want fresh module state or need to replace a dependency
without changing production code or the process-wide `package.loaded` table.

The basic workflow is:

1. Create a TestBed.
2. Load the code under test through the TestBed.
3. Exercise the returned module or script.
4. Close the TestBed.

> TestBed isolates the Lua dependency graph it loads. It is not a security
> sandbox and does not undo changes to files, screens, hooks, plugins, game
> state, shared tables, userdata, or native APIs.

## Quick start

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new()
local controller = bed:require('my_plugin.controller')

assert(controller.status() == 'ready')

bed:close()
```

Run standalone tests from your project root. By default, TestBed searches for
modules in:

1. `src/scripts_modinstalled`
2. `src`
3. `.`

It searches `src/scripts_modinstalled` for annotated scripts. Missing default
directories are ignored.

For example, `bed:require('my_plugin.controller')` can load:

```text
my-plugin/
|-- src/
|   `-- my_plugin/
|       `-- controller.lua
`-- tests/
    `-- controller_spec.lua
```

## Loading code versus configuring imports

These operations have different jobs:

| Operation                             | What it does                                                            |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `bed:require('my_plugin.controller')` | Loads a Lua module as an entry point.                                   |
| `bed:reqscript('my_plugin/state')`    | Loads an annotated DFHack script as an entry point.                     |
| An `imports` entry                    | Changes how a named module or script is resolved if something loads it. |

An import does **not** load anything by itself. It registers a replacement for
an exact dependency file. You still call `bed:require()` or
`bed:reqscript()` to start loading the graph.

For example:

```lua
local MOCK_STATE = {
    status='ready',
}

local bed = TestBed.new{
    imports={
        {
            provide={kind='script', name='my_plugin/state'},
            use_value=MOCK_STATE,
        },
    },
}

local panel = bed:reqscript('my_plugin/panel')
```

Here, `bed:reqscript('my_plugin/panel')` loads the panel. If that panel calls
`dfhack.reqscript('my_plugin/state')`, TestBed returns the configured table
instead of loading the normal state script.

Without a matching import, `bed:require()` searches `module_roots` and
`bed:reqscript()` searches `script_roots`.

Source-loaded scripts must declare annotated module mode:

```lua
--@ module=true

local M = {}
return M
```

Module and script names are separate. These imports do not refer to the same
dependency:

```lua
{provide={kind='module', name='my_plugin.state'}, ...}
{provide={kind='script', name='my_plugin.state'}, ...}
```

## Replacing dependencies

Pass an `imports` array to `TestBed.new()`. Each import identifies a dependency
by its `kind` and logical `name`, then selects one replacement strategy.

### Supply a fake value

Use `use_value` for most test doubles:

```lua
local MOCK_CLOCK = {
    now=function() return 42 end,
}

local bed = TestBed.new{
    imports={
        {
            provide={kind='module', name='my_plugin.clock'},
            use_value=MOCK_CLOCK,
        },
    },
}

local controller = bed:require('my_plugin.controller')
assert(controller.timestamp() == 42)
bed:close()
```

The supplied value is borrowed, not copied. A module value can be any non-`nil`
Lua value, including `false`. A script value must be a table.

The entry point must be loaded through the TestBed. If you load it first with
the normal `require()`, it captures its normal dependencies before TestBed can
replace them.

### Load a specific source file

Use `use_source` to load a test implementation inside the private graph:

```lua
{
    provide={kind='module', name='my_plugin.storage'},
    use_source='tests/fakes/in_memory_storage.lua',
}
```

Relative paths start from the consumer project root. The filename does not
need to match the provided dependency name.

### Alias another dependency

Use `use_existing` to return the same object as another dependency in the same
namespace:

```lua
{
    provide={kind='module', name='my_plugin.clock_alias'},
    use_existing={kind='module', name='my_plugin.clock'},
}
```

### Borrow from a live DFHack process

Live component tests can use `use_host=true`:

```lua
{
    provide={kind='module', name='gui.dialogs'},
    use_host=true,
}
```

This borrows the value through the live host's module or script loader and
preserves its identity. It does not make that host-owned dependency graph
private. Standalone TestBeds reject `use_host` because they have no live host.

## Testing a live component

To replace dependencies while a component is loaded, give `ds.mount()` a
module or script descriptor. DwarfSpec loads and constructs the component in a
fresh, mount-owned TestBed.

```lua
local MOCK_STORAGE = {
    read=function() return 'test value' end,
}

ds.mount({
    kind='module',
    name='my_plugin.save_panel',
    export='SavePanel',
}, {
    title='Saved value',
}, {
    imports={
        {
            provide={kind='module', name='my_plugin.storage'},
            use_value=MOCK_STORAGE,
        },
    },
})

assert(ds.get('value'):text() == 'test value')
```

The three arguments are kept separate:

1. The descriptor identifies the component source and optional export.
2. The mount-options table supplies constructor attributes and mount options.
3. The TestBed configuration controls dependency loading.

Do not put TestBed fields in the mount-options table. You can omit `export`
when the loaded source returns the component class directly, and you can omit
the third argument when no custom TestBed configuration is needed.

Use `kind='script'` and a slash-separated name for an annotated script
descriptor. Ordinary `ds.mount(ComponentClass, options)` calls do not create a
TestBed because the class and its dependencies are already loaded.

DwarfSpec automatically borrows these foundational host modules for live
descriptor mounts:

- `class`
- `utils`
- `gui`
- `gui.widgets`
- `gui.dwarfmode`

This preserves DFHack class identity. Add explicit `use_host=true` imports for
other host modules. User imports override automatic imports with the same
token. Set `component_imports=false` only when you intentionally want to
disable all automatic component imports.

DwarfSpec unmounts and destroys the component before closing its TestBed. Do
not close a mount-owned TestBed yourself.

## Configuration

`TestBed.new(config)` and the third argument to a descriptor mount accept the
same fields:

| Field               | Purpose                                                | Default                                               |
| ------------------- | ------------------------------------------------------ | ----------------------------------------------------- |
| `module_roots`      | Ordered roots searched by private `require()` calls.   | `src/scripts_modinstalled`, `src`, `.`                |
| `script_roots`      | Ordered roots searched by private `reqscript()` calls. | `src/scripts_modinstalled`                            |
| `globals`           | Extra or replacement values in the source environment. | `{}`                                                  |
| `imports`           | Exact module and script replacements.                  | `{}`                                                  |
| `component_imports` | Enables automatic live component imports.              | `false` standalone; `true` for live descriptor mounts |

Supplying `module_roots` or `script_roots` replaces its complete default list;
it does not extend it. Relative roots start from the working directory for a
standalone bed and from the active project root for a live mount.

Use `globals` for code that reads a global instead of importing a dependency:

```lua
local bed = TestBed.new{
    globals={
        BUILD_MODE='test',
        dfhack={
            getTickCount=function() return 1000 end,
        },
    },
}
```

When you provide `globals.dfhack`, it becomes the complete DFHack API backing
for that bed. Missing members do not fall through to the live DFHack table.
Loader globals such as `require`, `package`, `load`, and `dfhack` are reserved
and cannot be replaced as ordinary global fields.

## Isolation and cleanup

Each TestBed has private module and script caches, a private `package` state,
and private loader functions for its source graph. Two beds can therefore load
the same source and receive different module state:

```lua
local first = TestBed.new()
local second = TestBed.new()

assert(first:require('my_plugin.state') ~=
       second:require('my_plugin.state'))

first:close()
second:close()
```

TestBed does not copy or restore values supplied through `use_value`,
`globals`, or `use_host`. It also cannot restore external effects such as file
writes, timers, hooks, screens, plugins, or game actions. Clean up those
effects separately.

Close standalone beds deterministically, including after a load failure:

```lua
local bed = TestBed.new(config)
local ok, result = pcall(function()
    return bed:require('my_plugin.controller')
end)
bed:close()
assert(ok, result)
```

`close()` is safe to call more than once. After closing, TestBed-owned loader
functions fail with `TestBed is closed`.

## Troubleshooting

- **A fake is ignored:** load the entry point through `bed:require()` or
  `bed:reqscript()`, and make sure the import's `kind` and `name` exactly match
  the dependency request.
- **A module is missing:** run from the consumer root or set `module_roots`.
  Remember that a custom list replaces the defaults.
- **A script is missing:** check `script_roots`, use a slash-separated script
  name, and add `--@ module=true` to the source.
- **A component fails a class check:** borrow foundational DFHack modules from
  the host. Live descriptor mounts do this automatically by default.
- **State still leaks:** check whether it belongs to a borrowed value or an
  external resource. TestBed only owns the source graph it loads.

## API summary

```lua
local TestBed = require('dwarfspec.testbed')

local bed = TestBed.new(config) -- config is optional
local module, loader_data = bed:require('module.name')
local script = bed:reqscript('script/name')
bed:close()
```

For exhaustive loader behavior and isolation details, see the
[TestBed technical reference](../docs/testbed.md).
