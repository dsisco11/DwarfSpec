# Source-file-focused TestBed refactor proposal

## Status

This proposal is accepted as the design contract for implementation planning.
It does not describe a completed implementation.

## Summary

Refactor TestBed so that a resolved source file is the primary identity of a
dependency. `require()` and `dfhack.reqscript()` remain supported ways for
production code to reach dependencies, but they become request adapters at the
TestBed boundary. They no longer determine the identity used for
providers, caching, aliases, or diagnostics. `mkmodule()` remains a bed-local,
name-based private-package helper that immediately publishes a newly created
module environment through `package.loaded`; it does not resolve or identify a
source.

The current provider form:

```lua
{
    provide={kind='module', name='my_plugin.clock'},
    use_value=MOCK_CLOCK,
}
```

will become source-focused:

```lua
{
    target='src/my_plugin/clock.lua',
    use_value=MOCK_CLOCK,
}
```

The provider applies when any supported TestBed loader resolves a request
to that target file. Callers do not specify whether the target is reached with
`require()` or `reqscript()`.

## Motivation

TestBed exists to construct isolated source-loading state for consumer files
and replace selected files with test-controlled implementations. Its current
provider model instead identifies dependencies by the pair `(kind, name)`,
where `kind` is `module` or `script`.

That loader-token identity has several undesirable consequences:

- a test must describe how production code imports a dependency instead of
  identifying the dependency source it wants to replace;
- the same resolved filename can have separate module and script providers;
- changing a production import from `require()` to `reqscript()` forces an
  otherwise unrelated test configuration change;
- two logical names that resolve to the same file are treated as unrelated
  dependencies;
- `use_source` is easy to misread because `provide` names a loader token while
  `use_source` names a file; and
- provider diagnostics emphasize loader namespaces rather than the source
  files the test is intended to control.

The current implementation reflects this model directly. It stores separate
module and script provider maps and consults them before resolving a source
path. The refactor will invert that order: resolve source candidates first,
then consult one registry keyed by canonical source identity.

## Goals

- Make the source file being provided explicit in every user-configured
  provider.
- Remove `kind` from ordinary TestBed provider configuration.
- Make one canonical absolute target path one TestBed source identity, even
  when multiple logical names can reach it. A `use_source` provider is the
  deliberate exception that executes replacement contents under that target
  identity.
- Allow `require()` and `reqscript()` to share provider selection without
  erasing their production-compatible call behavior.
- Preserve `mkmodule()` as an authoritative name-based private-package helper
  that immediately publishes any environment it creates, so supported circular
  module imports continue to work without making the publication source-owned
  state.
- Keep providers deterministic when roots, `package.path`, or aliases
  produce multiple candidate files.
- Reject provider targets that do not resolve to readable production source
  files.
- Keep TestBed framework-neutral and usable without a live DFHack process.
- Preserve mount-scoped ownership and cleanup for live descriptor mounts.
- Produce diagnostics in terms of source paths, with request operation and
  operand included only as context.
- Create one deterministic warning record and perform the defined delivery
  attempt for each user-configured provider that was never selected before its
  TestBed closes.

## Non-goals

- Treating TestBed as a security sandbox.
- Changing the behavior of process-global Lua or DFHack loaders.
- Requiring production code to stop using `require()`, `mkmodule()`, or
  `dfhack.reqscript()`.
- Automatically restoring files, hooks, timers, screens, plugins, native
  state, or other effects outside TestBed-owned loader state.
- Resolving filesystem symlinks or imposing project-directory containment.
- Making borrowed host dependency graphs private retroactively.
- Preserving the current `(kind, name)` provider model inside the new core.

## Terminology

### Source reference

A source reference is the path a user writes in configuration. It is normally
relative to the effective consumer root for convenience:

```text
src/my_plugin/clock.lua
```

TestBed resolves the reference to an absolute path before it is registered or
compared. Users may also supply a normal absolute path for a source outside the
consumer project. On Windows, this includes drive-absolute and UNC paths but
excludes drive-relative and device-namespace paths.

### Source identity

A source identity is TestBed's canonical internal filename. It uses an
absolute path, forward slashes, and lexically normalized `.` and `..` segments.
On Windows, deterministic ASCII case folding makes the complete path
case-insensitive. On other platforms, path identity remains case-sensitive.
TestBed does not use `realpath()` or resolve symlinks.

This extends the existing TestBed lexical path policy by folding the complete
Windows path and by making the normalized filename the source-registry key.
Symlinks, hard links, and path spellings that remain distinct after the
declared lexical normalization may still create distinct source identities
even when the filesystem ultimately reaches the same physical file.

The replacement-content path supplied through `use_source` is resolved and
validated but deliberately does not become a source identity. The existing
provider target remains the identity while the replacement contents execute.

### Request context

Request context is transient information retained on the active load stack for
resolution, circular-dependency diagnostics, and errors. It includes:

- the calling source identity, or no caller for a root request;
- the operation: `require`, `reqscript`, or direct `load`;
- the request operand, which is a logical name for `require` and `reqscript`
  or a source reference for `load`; and
- the resolved target source identity once resolution succeeds.

Request context is not a persistent relationship in a dependency graph. The
operation and request operand do not become part of the target identity.

### Provider

A provider is a test policy attached to an existing target source identity. It
selects one of the supported strategies: a value, another source file, or a
shared existing source identity. It replaces how that readable production
source is supplied within the TestBed.

## Proposed public API

### Source-targeted providers

Replace the `imports` configuration field with `providers`. Each provider has
one required `target` source reference:

```lua
local MOCK_CLOCK = {
    now=function() return 42 end,
}

local bed = TestBed.new{
    providers={
        {
            target='src/my_plugin/clock.lua',
            use_value=MOCK_CLOCK,
        },
    },
}
```

Every target is resolved relative to the effective consumer root when the
TestBed is constructed and must identify a source file readable through the
configured source interface. A missing or unreadable target is a configuration
error. Duplicate canonical targets are also configuration errors, including
targets written with lexically equivalent paths.

Each provider must specify exactly one of `use_value`, `use_source`, or
`use_existing`. Supplying none or more than one is a configuration error.
`use_value=nil` is indistinguishable from an omitted Lua table field and
therefore counts as no strategy; providers cannot use it to represent a
supplied `nil` value.

### Provider strategies

`use_value` continues to return the exact borrowed value:

```lua
{
    target='src/my_plugin/clock.lua',
    use_value=MOCK_CLOCK,
}
```

`use_source` executes a provided file under the target source identity:

```lua
{
    target='src/my_plugin/storage.lua',
    use_source='tests/fakes/in_memory_storage.lua',
}
```

The provided filename is not a second source identity. If the same fake
file is used for two targets, TestBed creates two isolated target nodes. Use
`use_existing` when shared identity is intended. The replacement-content file
must itself be readable when configuration is validated.

`use_existing` names another source reference and lazily resolves that source
node:

```lua
{
    target='src/my_plugin/clock_alias.lua',
    use_existing='src/my_plugin/clock.lua',
}
```

The referenced source must identify a file that is readable during
configuration validation, but it does not need to be loaded first. Its own
provider, if any, is applied normally. Self-aliases and longer `use_existing`
cycles are errors reported with the complete source chain. The request reaching
the alias must be compatible with the referenced source's execution contract.

Host borrowing is not a provider strategy. The live adapter owns the narrow
automatic fallback policy described under **Live host integration**; ordinary
providers remain source-focused and contain no host loader operation or
logical name.

### Unused-provider warnings

Each user-configured provider begins unused. TestBed marks it used at definitive
provider selection, before provider-specific contract validation, alias
traversal, or source loading. A selected provider remains used even if
compatibility validation, its strategy, or subsequent source execution fails.
Merely validating configuration or generating a matching candidate path does
not mark a provider used.

On the first `bed:close()`, TestBed creates one warning record for each provider
that remains unused and performs the delivery defined below. Records follow the
original provider declaration order and include the configured target,
canonical target, and selected strategy:

```text
TestBed unused provider: target "src/my_plugin/clock.lua"
  resolved to "D:/project/src/my_plugin/clock.lua" (use_value)
```

Only user-configured providers participate. Internal source nodes, preload and
custom-searcher results, and automatic live host fallbacks do not produce
unused-provider warnings.

`use_existing` marks its own target provider used when the alias is selected.
The referenced target's provider is marked used only if lazy resolution
selects it. Repeated provider use produces no additional warning or event.

Warnings are processed once even when `close()` is called repeatedly. The first
close snapshots one unused-provider warning record per provider in declaration
order, completes cleanup of TestBed-owned source state, and then delivers those
records.

The warning sink is an internal constructor or live-adapter capability, not a
public `TestBedConfig` field. Standalone construction defaults it to standard
error. Live descriptor mounts inject DwarfSpec's host diagnostic sink. Focused
tests inject a recording sink instead of writing to a real process stream.

Delivery is per record and preserves order. TestBed attempts the active sink
once for each record. If a non-default sink raises, TestBed attempts standard
error once for that record, disables the failed sink, and sends all remaining
records directly to standard error. If standard error itself fails, TestBed
suppresses that delivery error and continues processing later records.
Warning-delivery failure never prevents source-state cleanup, makes `close()`
raise, or causes records to be processed again on a later `close()`.

For standalone tests, `close()` defines the end of the TestBed lifetime. For
live descriptor tests, DwarfSpec processes warnings while closing the
mount-owned TestBed after component destruction and unmounting. A TestBed that
is never closed cannot report unused providers reliably.

### Direct source loading

Add a source-first entry point:

```lua
local controller = bed:load('src/my_plugin/controller.lua')
```

`bed:load(source)` resolves a source reference directly, applies any matching
provider, and returns the source node's value. This becomes the preferred
entry point for new tests and source descriptors.

The direct target must be readable. `use_value` returns its configured value
after validation against the target's declared contract; an annotated script
target requires a table and an ordinary module target requires a non-`nil`
value. `use_source` executes according to the compatible replacement source
contract, and `use_existing` adopts the referenced source's contract and value.
A missing or unreadable direct target fails with the ordinary source-resolution
diagnostic.

When a loader-adapter request resolves to the same file-backed target through
the default file-source searcher for `require()` or the script resolver for
`reqscript()`, direct loading and loader-adapter access share the same source
node, execution state, and default source result. Loading that source directly
and then reaching it through either adapter, or doing those operations in the
reverse order, does not execute a cacheable source twice. A `require()` request
satisfied earlier by `package.loaded`, preload, or a custom searcher does not
access that file-backed node and retains its ordinary private-package or
virtual-source behavior. A module name can still expose its own value through
private `package.loaded`; such a name-specific publication does not replace the
default source result unless the source explicitly returns that value.

`bed:require(name)` and `bed:reqscript(name)` remain supported as compatibility
entry points and as the implementations bound into production source
environments. They resolve the requested name to a source identity before
loading it.

### Source-focused component descriptors

Live component descriptors should identify their source directly:

```lua
ds.mount({
    source='src/my_plugin/save_panel.lua',
    export='SavePanel',
}, {
    title='Saved value',
}, {
    providers={
        {
            target='src/my_plugin/storage.lua',
            use_value=MOCK_STORAGE,
        },
    },
})
```

The descriptor no longer contains `kind` or a loader-specific logical name.
DwarfSpec asks the mount-owned TestBed to load the descriptor source and then
selects `export` as it does today.

## Resolution model

### Request resolution

Each file-backed loader adapter converts a logical request into an ordered list
of source candidates:

- `require('my_plugin.clock')` uses the bed-local `package.path`, including
  both `?.lua` and `?/init.lua` templates;
- `reqscript('my_plugin/clock')` uses the configured script roots and the
  DFHack script filename convention; and
- `load('src/my_plugin/clock.lua')` supplies one direct candidate.

Every candidate is resolved to a canonical absolute path before lookup.
Resolution selects the first candidate that exists as a readable file and then
consults the provider registry for that source identity. A provider cannot make
a missing candidate selectable or shadow a later readable candidate.

Relative templates inserted into the mutable private `package.path` resolve
from the process current directory, matching ordinary Lua path behavior.
Configured roots and source references continue to resolve from the effective
consumer root. Diagnostics distinguish the two bases.

If no candidate is readable, the error reports:

- the request operation and operand;
- all canonical candidate paths in precedence order;
- the configured roots or private path used to generate them; and
- the current source dependency chain.

### File and virtual source nodes

The TestBed owns a source-node registry keyed by source identity. Most nodes
represent canonical file paths. Private `package.preload` entries and custom
`package.searchers` can produce values without a source file, so the registry
also supports adapter-owned virtual identities.

The default preload searcher assigns `virtual:preload:<name>` identities.
Every custom-searcher result receives a stable bed-local virtual identity based
on the searcher and requested name. Loader data remains ordinary loader data
and does not provide or alter source identity. Virtual identities are
diagnostic and cache keys; they are not valid public provider targets. TestBed
defines no custom-searcher protocol for claiming a file-backed identity.

The private `package.preload` and `package.searchers` tables remain mutable and
authoritative. Their ordering is preserved. Source-targeted provider lookup
occurs inside the default file-source searcher after earlier searchers have had
their normal opportunity to satisfy the request.

### Cache and publication semantics

The source-node registry is separate from the public private-package tables.
It records source ownership, load status, request aliases, execution contract,
the default execution result, and loader data. Name-specific publications
belong to the private package state instead of to source nodes.
`package.loaded[name]` continues to expose public values, not internal
source-node objects.

The module adapter preserves Lua-compatible result rules:

- a non-`nil` loader result becomes the default source result and
  `package.loaded[name]`;
- a `nil` result gives the source a default result of `true`, while preserving
  a value published specifically for the requesting module name;
- a `nil` result without a requesting-name publication exposes `true` for that
  name, even if the source published a different module name;
- a `false` result remains non-cacheable and allows the same source node to be
  executed again; and
- a failed load clears in-progress state and permits a later retry.

Before invoking a module loader, the adapter records the requesting name's
pre-attempt `package.loaded` value, which is normally `nil` or `false`. If the
loader fails, the adapter restores that exact pre-attempt value even when the
loader called `mkmodule()` with the requesting name. Changes made under other
module names remain authoritative private-package side effects. Restoring the
requesting slot prevents a partially published environment from suppressing
the promised retry without assigning the publication to a source node.

Direct loading returns the default source result. It never selects or infers a
result from a name-specific `package.loaded` publication. A later module alias
receives its name-specific publication when one exists and otherwise receives
the default source result.

The loader-data value is returned only for an execution attempt. Cache hits
continue to return no loader data.

Private name-to-source alias maps are maintained separately from
`package.loaded` and the script-name cache. Different names resolving to the
same file share one cacheable source result. Repeating a cached logical request
retains its alias even if later `package.path` mutation would resolve that name
differently.

Source ownership of a name-to-source alias is separate from ownership of the
value currently stored at that name. A requesting alias remains attached to its
source when the module adapter preserves a same-name value published by
`mkmodule()`. The adapter records that preserved value as the alias's expected
private-package value for later override detection, but the value does not
become source-node state. Source-wide invalidation clears the private
`package.loaded` entry for every still-attached alias, including one whose
expected value came from `mkmodule()`. A detached caller override remains
protected by the rules below.

Direct mutation of `package.loaded` remains authoritative at the requesting
name. Assigning a non-`nil`, non-`false` value overrides that name without
changing the underlying source node or its other aliases. When TestBed next
observes that the value differs from the alias's recorded expected
private-package value, it detaches that name from source ownership. The
explicit override then survives later source invalidation through another
alias.

Clearing an owned alias, or setting it to `false`, invalidates that alias and
the cacheable source result on its next request. TestBed then clears only the
other still-owned aliases for that node and re-resolves the requested name
against the current searchers and `package.path`. This makes explicit reload
behavior source-wide without destroying detached caller overrides or allowing
two TestBed-owned generations of one source to coexist silently. The private
script cache is not publicly mutable, so this detachment rule applies only to
module aliases.

Script nodes always cache their environment table after successful execution.
Failed script loads clear in-progress state and remain retryable.

Circular dependency detection uses source identities. Diagnostics also show
the transient request contexts from the active load stack so a user can see
the logical names or direct references and operations that formed the cycle.

### `mkmodule()` publication

`mkmodule(name)` does not resolve a dependency or identify a source. It first
consults the authoritative private `package.loaded[name]`. When that entry is
non-`nil` and non-`false`, `mkmodule()` returns the exact cached value, whatever
its type, without creating or replacing an environment. Otherwise it creates a
stable bed-local module environment, immediately publishes that environment at
the name, and returns it. The publication is owned by the private package
state, not by the active source node. Production code can bind `_ENV` to a
newly created or previously published environment table:

```lua
local _ENV = mkmodule('my_plugin.clock')

function now()
    return 42
end

return _ENV
```

A later `require(name)` can observe that partial module environment during a
circular import. If a loader requested under that name later returns a
non-`nil` value, the explicit return replaces the requesting name's published
value. A `nil` return preserves it. Calling `mkmodule()` outside active source
execution has the same name-based behavior and creates no source node.

Direct loading does not infer its result from `mkmodule()` calls. It returns
the source's default result under the cache rules above. A conventional DFHack
module explicitly returns its `_ENV`, so that environment naturally becomes
the default result without any special source-to-publication relationship.

### Execution contract

Source identity and source execution are related but separate concerns. The
file determines its execution contract:

- a DFHack source declaring annotated module mode is executed as a script
  environment and produces that environment table;
- an ordinary Lua source is executed as a module and produces its returned
  module value; and
- `use_value` is source-less and returns its configured value directly.

`reqscript()` reaching an ordinary, non-annotated source is an error.
`require()` reaching an annotated script source is also an incompatible-access
error. TestBed never creates a second identity or executes the file through the
wrong adapter. Callers must use the operation declared by the source.

A source provider supplied with `use_source` must have an execution contract
compatible with the readable target. TestBed compares their declarations
before execution.

`use_value` has no declared execution contract. It is valid through a module
request with any non-`nil` value and through a script request only when its
value is a table. The first request does not permanently classify the value;
later compatible requests to the same target reuse the same value. Script-table
validation therefore occurs at the source-access boundary, including direct
loading, because a provider no longer declares a loader kind. Direct loading
uses the readable target's declaration to select the applicable validation.

`use_existing` adopts the referenced node's execution contract. These rules
make behavior independent of request order.

## Live host integration

The live adapter is the one boundary where loader-specific information is
unavoidable: DFHack exposes host `require` and `reqscript` operations rather
than a general source-file loader.

The core TestBed remains source-keyed and exposes no special public naming
scheme for DFHack-owned files. A live request follows this order:

1. Run every private searcher in its configured order. Within the default
   file-source searcher, select the first readable consumer source and apply its
   matching provider, if any.
2. If any private searcher returns a loader, use that result and do not consult
   automatic host fallback. This includes custom searchers positioned after the
   default file-source searcher.
3. Only after every private searcher declines the request may the live adapter
   borrow an approved foundational dependency from the DFHack host.
4. Record a discovered host filename as an internal canonical source
   identity when possible, or use an internal virtual identity for native or
   preloaded host values.

The automatic foundational fallbacks apply only to `require` module requests
for exactly `class`, `utils`, `gui`, `gui.widgets`, and `gui.dwarfmode`.
`reqscript` never receives an automatic foundational fallback. These fallbacks
preserve real DFHack class identity without taking precedence over a readable
consumer source or user-configured source provider.

The boolean `component_host_fallbacks` configuration field controls this
behavior. It defaults to `false` for standalone TestBeds and `true` for live
descriptor mounts. Setting it to `false` on a live mount disables all
automatic foundational fallbacks. Setting it to `true` without a live adapter
is a construction-time configuration error. It replaces the loader-focused
`component_imports` field.

For example, production code continues to use an ordinary request:

```lua
local gui = require('gui')
```

A test can preempt the live fallback with a provider for a readable consumer
source target:

```lua
providers={
    {
        target='src/gui.lua',
        use_value=MOCK_GUI,
    },
}
```

No `@host/`, URI, encoded logical name, or installation-relative path is part
of the public API. Host filenames and virtual identities are live-adapter
implementation details and are not valid public provider targets. TestBed has
no public provider mechanism for borrowing an arbitrary host module or script;
additional foundational dependencies require an explicit amendment to the
versioned live-adapter fallback policy.

## Configuration and path behavior

The effective consumer root remains:

- the current process directory for standalone TestBeds; and
- the active DwarfSpec project root for live descriptor mounts.

`module_roots` and `script_roots` continue to define how existing production
requests produce candidate source files. They no longer partition provider
identity.

Relative `target`, `use_source`, `use_existing`, and direct `load()` paths all
resolve from the same effective consumer root. Normal absolute paths remain
accepted. On Windows, TestBed accepts drive-absolute and UNC paths and rejects
ambiguous drive-relative paths such as `C:src/clock.lua` and device-namespace
paths such as `\\?\C:\src\clock.lua` or `\\.\device`.

Lexical normalization must make these references identical:

```text
src/my_plugin/clock.lua
./src/my_plugin/clock.lua
src/my_plugin/../my_plugin/clock.lua
```

Windows path comparison folds ASCII case across the complete canonical path,
not only the drive letter. TestBed therefore does not distinguish files whose
Windows paths differ only by case, including on an unusually case-sensitive
Windows directory. Non-Windows path comparison preserves case.

## Compatibility policy

The refactor preserves these existing TestBed contracts:

- private `package.loaded`, `package.preload`, `package.searchers`, and
  `package.path` remain bed-local, mutable, and authoritative;
- module loaders preserve `nil`, `false`, explicit publication, loader-data,
  and failed-retry behavior described above;
- `mkmodule()` immediately publishes any environment it creates and continues
  to break supported circular module dependencies;
- annotated scripts publish their environment before execution and clear
  failed state for retry;
- `require('dfhack')` remains the reserved bed-local facade and cannot be
  redirected through `package.loaded`, preload, custom searchers, or a source
  provider;
- protected loader bindings and the `dfhack` facade cannot be replaced through
  ordinary source global writes; and
- close invalidates all retained loaders and clears TestBed-owned source
  references.

The refactor intentionally changes these contracts:

- public provider identity changes from `(kind, name)` to a canonical
  source target;
- public `use_host` providers are removed; host borrowing is owned exclusively
  by the versioned live-adapter fallback policy;
- source-focused descriptors replace loader-specific descriptors;
- automatic foundational host modules change from provider-before-source
  precedence to fallback only after every private searcher declines, as
  defined under **Live host integration**;
- provider targets that do not identify readable source files are rejected
  instead of creating provider-only virtual candidates;
- Windows canonical identity changes from drive-prefix-only normalization to
  deterministic ASCII case folding across the complete path;
- incompatible access to a declared module or script source fails rather than
  creating a second identity; and
- explicit invalidation through a known `package.loaded` alias invalidates the
  shared source generation and its other aliases.

All other behavioral changes require an explicit amendment to this proposal.

## Migration

TestBed has not been released, so this proposal makes an immediate breaking
change without a compatibility adapter. The `imports` field, `provide` token,
`kind`, public `use_host` strategy, `component_imports`, and `(kind, name)`
registry are removed together. Configuration using any legacy field or
strategy is rejected with an error that identifies the unsupported input and
points to `providers` or `component_host_fallbacks`, as appropriate.

The implementation must not silently translate legacy tokens. A token can
resolve differently after private `package.path` mutation, can represent a
provider-only dependency with no discoverable source, and can distinguish
module and script namespaces for the same name. Retaining that behavior would
preserve the loader-focused model outside the new core without serving a
released compatibility contract.

All repository consumers, fixtures, declarations, technical documentation,
and wiki examples migrate in the same change.

The refactor also updates:

- public LuaLS declarations;
- descriptor validation and overload declarations;
- unit and live fixtures;
- the technical TestBed reference;
- the end-user TestBed wiki page; and
- error messages and loader-data diagnostics.

## Implementation outline

1. Introduce an immutable canonical `SourceId` value and source-targeted
   provider configuration that validates readable targets.
2. Extend path resolution to return ordered canonical absolute candidates and
   select the first readable source.
3. Replace the split token registry with one source provider registry.
4. Introduce the source-node registry, alias maps, virtual-source support, and
   a transient active request stack.
5. Route private `require` and `reqscript` through source resolution before
   provider lookup, while preserving `mkmodule` as immediate name-based
   publication in the private package state.
6. Preserve mutable preload/searcher and public package-cache behavior around
   the new registry.
7. Add direct source loading and source-focused component descriptors.
8. Move script-result validation and incompatible-access errors to the source
   request boundary.
9. Adapt live host borrowing as a fallback only after every private searcher
   declines, without exposing host naming through the public API.
10. Track provider selection, create ordered unused-provider warning records,
    and perform their defined delivery attempts during close.
11. Remove the legacy token implementation and update declarations,
   documentation, fixtures, and diagnostics.

Each step must preserve deterministic close behavior and must not mutate the
process-wide `package.path`, `package.loaded`, or DFHack script cache.

## Verification

Focused unit coverage must prove:

- provider configuration accepts exactly one of `use_value`, `use_source`, or
  `use_existing` and rejects missing or competing strategies,
  `use_value=nil`, and the removed `use_host` strategy;
- provider construction separately rejects a missing or unreadable `target`,
  `use_source` replacement, or `use_existing` reference before any source is
  loaded;
- lexically equivalent target paths produce one provider identity;
- two different logical module names resolving to one file share one source
  node and one result;
- module and script adapters resolving to one target consult the same
  provider; compatible protocol-neutral values are shared, while declared
  contract mismatches fail before execution;
- a missing earlier file candidate does not become selectable because a later
  readable target has a provider;
- an earlier preload or custom-searcher result retains normal precedence over
  the default file-source searcher;
- `?.lua` and `?/init.lua` candidates retain normal precedence;
- private `package.path` mutation affects new names without changing an
  already-cached name-to-source alias;
- relative private `package.path` templates resolve from the process current
  directory, while configured source references resolve from the consumer
  root;
- clearing or setting `false` through a known `package.loaded` alias performs
  the declared source-wide invalidation and re-resolution;
- a still-attached alias whose expected cached value came from same-name
  `mkmodule()` publication participates in source-wide invalidation, while its
  value never becomes source-node state;
- a detached explicit `package.loaded` override survives invalidation through
  another alias to the same source;
- module `nil`, `false`, explicit publication, loader-data, and failed-retry
  behavior remains compatible;
- a failed module loader restores the requesting name's exact pre-attempt
  `package.loaded` value after same-name `mkmodule()` publication, so the next
  request retries, while publications under other names remain untouched;
- `mkmodule()` returns any authoritative non-`nil`, non-`false`
  `package.loaded` value exactly as stored; otherwise it creates and immediately
  publishes a stable bed-local environment, supports circular imports, behaves
  the same inside and outside source execution, and creates no source-node
  ownership relationship;
- mutable preload and custom searchers retain their order and produce stable
  bed-local virtual source identities;
- `use_source` isolates the provided source under the target identity;
- `use_existing` shares the referenced source identity;
- an unprimed `use_existing` lazily loads its readable target, applies the
  target's own strategy, and reports self and cyclic targets;
- provider and dependency cycles report canonical source chains;
- incompatible module/script access fails without executing a source twice;
- `use_value` is protocol-neutral but enforces table results at a script
  request boundary and when directly loading an annotated script target;
- direct loading exercises readable targets for every compatible provider
  strategy and rejects missing or unreadable targets;
- when the default file-source searcher for `require()` or the script resolver
  for `reqscript()` selects the same readable target, direct loading followed by
  either adapter, and either adapter followed by direct loading, share one
  source node, execution, and default source result without executing a
  cacheable source twice;
- a `package.loaded`, preload, or custom-searcher result that satisfies an
  `require()` request before the default file-source searcher can select a file
  remains separate from a direct load of that file in either access order and
  is never attached to the file-backed source node;
- direct loading of `nil`-returning modules yields the default `true` result and
  never infers a result from same-name or different-name `mkmodule()`
  publications, while module names retain their name-specific values;
- filesystem-free canonicalization and candidate-resolution tests cover
  project-relative paths, normal absolute paths, Windows drive-absolute and UNC
  paths, rejected Windows drive-relative and device-namespace paths, and the
  declared platform case rules;
- standalone configuration remains independent from live-host support and
  rejects `component_host_fallbacks=true` during construction;
- the reserved `dfhack` facade and protected loader bindings cannot be
  intercepted by source providers;
- used providers create no warning record, while every unused user provider
  creates one record and receives the defined delivery attempt in declaration
  order on the first `close()`;
- provider selection marks the provider used before strategy execution, while
  candidate generation alone does not;
- a selected `use_source` provider remains used, and therefore does not warn,
  when its compatibility check or strategy execution fails;
- provider failures, lazy `use_existing`, preload/custom-searcher precedence,
  repeated `close()`, and an injected warning sink follow the warning contract;
- when a non-default warning sink fails, the failed record is attempted once on
  standard error, the sink is disabled, later records continue through standard
  error in declaration order, and source-state cleanup remains complete; and
- closing a TestBed invalidates every retained source loader and request
  adapter.

Declaration fixtures must prove that source-targeted configurations and
descriptors type-check through `providers` and `component_host_fallbacks`,
while `imports`, `kind`, `provide`, `use_host`, and `component_imports` are
rejected.

Focused live coverage must prove:

- source-focused descriptor mounts construct the intended component;
- source providers apply to transitive component dependencies;
- automatic foundational host fallbacks preserve real DFHack class identity;
- a custom searcher positioned after the default file-source searcher preempts
  automatic host fallback when it returns a loader;
- readable consumer module sources and ordinary source providers preempt
  automatic host fallback without special host-path syntax;
- `reqscript` requests never receive automatic foundational host fallback;
- file-backed and native/preloaded host identities remain internal;
- unused mount-owned providers warn after component destruction and unmounting
  when DwarfSpec closes the TestBed;
- separate mounts receive fresh TestBed-owned source state; and
- unmount destroys the component before closing its mount-owned TestBed.

Full validation must include the existing unit suite, source-declaration
checks, Lua syntax checks, package verification, and the established live
TestBed automation set.

## Acceptance criteria

The refactor is complete only when:

- the direct source entry point is exactly `bed:load(source)`;
- public TestBed configuration uses `providers` with source `target` values and
  uses `component_host_fallbacks` for automatic foundational live borrowing;
- `imports`, `provide`, loader `kind`, public `use_host`, and
  `component_imports` are removed immediately without a compatibility adapter;
- the core provider registry is keyed only by canonical source identity;
- request operations and operands remain transient active-load context rather
  than persistent graph relationships or source-node identity;
- one canonical absolute target source cannot be silently executed twice under
  separate module and script caches;
- direct loading and loader-adapter access in either order share the same
  source node, execution, and default source result when `require()` selects
  that same target through the default file-source searcher or `reqscript()`
  selects it through the script resolver, while `require()` requests satisfied
  earlier by `package.loaded`, preload, or a custom searcher remain separate;
- source-focused providers apply only to readable target source files;
- `mkmodule`, private package tables, module cache-result rules, custom
  searchers, and failed-load retry behavior satisfy the compatibility policy;
- automatic live host borrowing occurs only after every private searcher
  declines and remains limited to the versioned foundational allowlist;
- ordinary source providers take precedence over automatic live host fallback,
  with no special public host-source naming convention;
- the first close creates one ordered warning record and makes the defined
  delivery attempt for every unused user-configured provider, including the
  specified sink fallback behavior, without interfering with cleanup;
- canonical source paths use deterministic ASCII case folding across the
  complete path on Windows and preserve case on other platforms;
- standalone and live behavior retain their documented ownership and cleanup
  guarantees, and standalone construction rejects
  `component_host_fallbacks=true`;
- public declarations, technical documentation, and the wiki describe the
  source-file model consistently; and
- all required focused, full, declaration, package, and live checks pass.

## Accepted decisions

- The direct source entry point is `bed:load(source)`.
- Source-targeted configuration uses the `providers` field.
- The unreleased loader-token API is removed immediately without a legacy
  adapter.
- DFHack host filenames and virtual identities remain internal; public
  configuration has no special host-source naming format.
- Automatic foundational live borrowing is controlled by
  `component_host_fallbacks`.
- Canonical source identity uses deterministic ASCII case folding across the
  complete path on Windows and preserves case on other platforms.
- The first `close()` creates and attempts delivery of one warning, in
  declaration order, for every user-configured provider that was never
  selected.
- Every provider specifies exactly one of `use_value`, `use_source`, or
  `use_existing`; `use_value=nil` counts as an omitted strategy and is invalid.
- The public `use_host` provider strategy is removed. Host borrowing exists
  only as the live adapter's versioned automatic foundational fallback.
- Provider targets must resolve to readable production source files during
  TestBed construction; providers cannot create virtual file candidates.
- `target`, `use_source`, and `use_existing` paths must each identify readable
  files during configuration validation.
- Direct loading applies compatible provider strategies only to readable
  targets, validates `use_value` against the target's declared contract, and
  rejects missing or unreadable targets.
- Direct loading and `require()` or `reqscript()` share one source node and
  default source result in either access order when `require()` selects the same
  target through the default file-source searcher or `reqscript()` selects it
  through the script resolver, without executing that cacheable source twice.
  `require()` requests satisfied earlier by `package.loaded`, preload, or a
  custom searcher remain separate, and module names can still expose
  name-specific publications.
- Custom-searcher results always use stable bed-local virtual identities and
  cannot declare file-backed source metadata.
- Path validation accepts project-relative and normal absolute paths, including
  Windows drive-absolute and UNC paths, while rejecting Windows drive-relative
  and device-namespace paths. Path tests remain filesystem-free.
- Relative source references are configuration conveniences only; TestBed
  resolves them to canonical absolute identities before registration or
  comparison.
- Request operations, operands, and callers remain transient active-load
  context. TestBed does not persist dependency-edge records.
- `mkmodule()` is a name-based private-package helper. It returns an existing
  authoritative non-`nil`, non-`false` `package.loaded` value exactly, or
  creates and immediately publishes a stable environment when no such value
  exists. It creates no source node and no source-owned publication.
- `use_source` deliberately executes replacement contents under the readable
  provider target's identity; its replacement-content path is not another
  source identity.
- Automatic live host fallback runs only after every private searcher declines,
  including custom searchers positioned after the default file-source searcher.
- Standalone construction rejects `component_host_fallbacks=true`.
