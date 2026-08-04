# Source-file-focused TestBed refactor proposal

## Status

This proposal is accepted as the design contract for implementation planning.
It does not describe a completed implementation.

## Summary

Refactor TestBed so that a resolved source file is the primary identity of a
dependency. `require()` and `dfhack.reqscript()` remain supported ways for
production code to reach dependencies, but they become request adapters at the
edges of the TestBed graph. They no longer determine the identity used for
providers, caching, aliases, or diagnostics. `mkmodule()` remains a
publication operation and binds a module name to the source that is currently
executing instead of resolving another source.

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

TestBed exists to construct an isolated graph from consumer source files and
replace selected files with test-controlled implementations. Its current
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
  graph the test is intended to control.

The current implementation reflects this model directly. It stores separate
module and script provider maps and consults them before resolving a source
path. The refactor will invert that order: resolve source candidates first,
then consult one registry keyed by canonical source identity.

## Goals

- Make the source file being provided explicit in every user-configured
  provider.
- Remove `kind` from ordinary TestBed provider configuration.
- Make one canonical lexical source path one TestBed graph identity, even when
  multiple logical names can reach it.
- Allow `require()` and `reqscript()` to share provider selection without
  erasing their production-compatible call behavior.
- Preserve `mkmodule()` as immediate publication of a module environment
  associated with the currently executing source so circular module imports
  continue to work.
- Keep providers deterministic when roots, `package.path`, or aliases
  produce multiple candidate files.
- Preserve the ability to replace a source that is intentionally absent from
  the test filesystem.
- Keep TestBed framework-neutral and usable without a live DFHack process.
- Preserve mount-scoped ownership and cleanup for live descriptor mounts.
- Produce diagnostics in terms of source paths, with request method and
  logical name included only as context.
- Create one deterministic warning record and perform the defined delivery
  attempt for each user-configured provider that was never selected before its
  TestBed closes.

## Non-goals

- Treating TestBed as a security sandbox.
- Changing the behavior of process-global Lua or DFHack loaders.
- Requiring production code to stop using `require()`, `mkmodule()`, or
  `dfhack.reqscript()`.
- Automatically restoring files, hooks, timers, screens, plugins, native
  state, or other effects outside the source graph.
- Resolving filesystem symlinks or imposing project-directory containment.
- Making borrowed host dependency graphs private retroactively.
- Preserving the current `(kind, name)` provider model inside the new core.

## Terminology

### Source reference

A source reference is the path a user writes in configuration, normally
relative to the effective consumer root:

```text
src/my_plugin/clock.lua
```

Normal absolute paths remain supported for sources intentionally outside the
consumer project. On Windows, this includes drive-absolute and UNC paths but
excludes drive-relative and device-namespace paths.

### Source identity

A source identity is TestBed's canonical internal filename. It uses an
absolute path, forward slashes, and lexically normalized `.` and `..` segments.
On Windows, deterministic ASCII case folding makes the complete path
case-insensitive. On other platforms, path identity remains case-sensitive.
TestBed does not use `realpath()` or resolve symlinks.

This extends the existing TestBed lexical path policy by folding the complete
Windows path and by making the normalized filename the graph key. Symlinks,
hard links, and path spellings that remain distinct after the declared lexical
normalization may still create distinct source identities even when the
filesystem ultimately reaches the same physical file.

### Request edge

A request edge records how one source reached another source. It includes:

- the calling source identity;
- the operation, such as `require` or `reqscript`;
- the requested logical name; and
- the resolved target source identity.

The operation and logical name belong to the edge, not to the target's
identity.

### Provider

A provider is a test policy attached to a target source identity. It selects
one of the supported strategies: a value, another source file, a shared
existing source identity, or a value borrowed from the live host. A provider
can satisfy an existing source or act as a virtual source when the target file
is intentionally absent.

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
TestBed is constructed. Duplicate canonical targets are configuration errors,
including targets written with lexically equivalent paths.

Each provider must specify exactly one of `use_value`, `use_source`,
`use_existing`, or `use_host`. Supplying none or more than one is a
configuration error. `use_value=nil` is indistinguishable from an omitted Lua
table field and therefore counts as no strategy; providers cannot use it to
represent a supplied `nil` value.

### Provider strategies

`use_value` continues to return the exact borrowed value:

```lua
{
    target='src/my_plugin/clock.lua',
    use_value=MOCK_CLOCK,
}
```

`use_source` executes a provided file under the target source's graph
identity:

```lua
{
    target='src/my_plugin/storage.lua',
    use_source='tests/fakes/in_memory_storage.lua',
}
```

The provided filename is not a second graph identity. If the same fake
file is used for two targets, TestBed creates two isolated target nodes. Use
`use_existing` when shared identity is intended.

`use_existing` names another source reference and lazily resolves that source
node:

```lua
{
    target='src/my_plugin/clock_alias.lua',
    use_existing='src/my_plugin/clock.lua',
}
```

The referenced source does not need to be loaded first. Its own provider, if
any, is applied normally. An absent referenced source without a provider
fails when the alias is first requested. Self-aliases and longer
`use_existing` cycles are errors reported with the complete source chain. The
request reaching the alias must be compatible with the referenced source's
execution contract.

Host borrowing remains live-only, but its core registry entry is attached to a
source identity instead of a module or script token. The provider carries
explicit adapter metadata so its result does not depend on which request edge
happens to arrive first:

```lua
{
    target='src/my_plugin/platform.lua',
    use_host={operation='require', name='my_plugin.platform'},
}
```

`operation` is either `require` or `reqscript`. It describes how the provided
value is obtained from DFHack; it is not part of the target source
identity. Because the metadata is explicit, direct source loading, aliases,
and repeated access all borrow the same deterministic host value. A request
whose execution contract is incompatible with the configured host operation
fails before the host loader is called.

### Unused-provider warnings

Each user-configured provider begins unused. TestBed marks it used at definitive
provider selection, before provider-specific contract validation, alias
traversal, source loading, or host invocation. A selected provider remains used
even if compatibility validation, its strategy, or subsequent source execution
fails. Merely validating configuration or generating a matching candidate path
does not mark a provider used.

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
order, completes graph cleanup, and then delivers those records.

The warning sink is an internal constructor or live-adapter capability, not a
public `TestBedConfig` field. Standalone construction defaults it to standard
error. Live descriptor mounts inject DwarfSpec's host diagnostic sink. Focused
tests inject a recording sink instead of writing to a real process stream.

Delivery is per record and preserves order. TestBed attempts the active sink
once for each record. If a non-default sink raises, TestBed attempts standard
error once for that record, disables the failed sink, and sends all remaining
records directly to standard error. If standard error itself fails, TestBed
suppresses that delivery error and continues processing later records.
Warning-delivery failure never prevents graph cleanup, makes `close()` raise,
or causes records to be processed again on a later `close()`.

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

An absent direct target can be loaded when a provider supplies it. `use_value`
returns its configured value directly; `use_source` executes according to the
provided source's declared contract; `use_existing` adopts the referenced
source's contract and value; and `use_host` uses its explicit host operation
and name. An absent target without a provider fails with the ordinary
source-resolution diagnostic.

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

Every candidate is canonicalized before lookup. Resolution selects the first
candidate that either exists as a readable file or has a configured provider.
A provider therefore acts as a virtual source file and can
intentionally shadow a later real candidate.

Relative templates inserted into the mutable private `package.path` resolve
from the process current directory, matching ordinary Lua path behavior.
Configured roots and source references continue to resolve from the effective
consumer root. Diagnostics distinguish the two bases.

This rule preserves provider-only tests. For example, a `use_value` target
does not need a real production file in the test fixture as long as the target
is one of the candidates generated by the request.

If no candidate exists or is replaced, the error reports:

- the request operation and logical name;
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
the default execution result, name-specific publications, and loader data.
`package.loaded[name]` continues to expose public values, not internal
source-node objects.

The module adapter preserves Lua-compatible result rules:

- a non-`nil` loader result becomes `package.loaded[name]` and the source-node
  result;
- a `nil` result preserves a value published specifically for the requesting
  module name;
- a `nil` result without a requesting-name publication caches `true`, even if
  the source published a different module name;
- a `false` result remains non-cacheable and allows the same source node to be
  executed again; and
- a failed load clears in-progress state and permits a later retry.

The loader-data value is returned only for an execution attempt. Cache hits
continue to return no loader data.

Private name-to-source alias maps are maintained separately from
`package.loaded` and the script-name cache. Different names resolving to the
same file share one cacheable source result. Repeating a cached logical request
retains its alias even if later `package.path` mutation would resolve that name
differently.

Direct mutation of `package.loaded` remains authoritative at the requesting
name. Assigning a non-`nil`, non-`false` value overrides that name without
changing the underlying source node or its other aliases. When TestBed next
observes that the value differs from the value it published for the name, it
detaches that name from source ownership. The explicit override then survives
later source invalidation through another alias.

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
the request edges so a user can see the logical names and operations that
formed the cycle.

### `mkmodule()` publication

`mkmodule(name)` does not resolve a dependency. It creates or returns a stable
bed-local module environment, immediately publishes that environment through
`package.loaded[name]`, and associates the name-specific publication with the
active source node. The published environment is not necessarily the chunk's
original execution environment: production code can bind `_ENV` to the table
returned by `mkmodule()`.

A later `require(name)` can observe that partial module environment during a
circular import. If the source was requested under the same name and later
returns a non-`nil` value, the explicit return replaces the publication for
that requesting name. A `nil` return preserves the publication. If source A
was requested under one name but calls `mkmodule()` with a different name B,
a `nil` return caches `true` for A while B retains its published module
environment.

When `mkmodule(name)` is called without an active file-backed source, TestBed
preserves current behavior by creating or returning a bed-local virtual
publication node. Its public `package.loaded[name]` value is returned before
searchers or providers are consulted, while the reserved `dfhack` facade
continues to bypass mutable package state.

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

A source provider supplied with `use_source` must have an execution
contract compatible with the target. When the target exists, TestBed can
compare their declarations before execution. When the target is absent, the
provided source declaration establishes the contract.

`use_value` has no declared execution contract. It is valid through a module
request with any non-`nil` value and through a script request only when its
value is a table. The first request does not permanently classify the value;
later compatible requests to the same target reuse the same value. Script-table
validation therefore moves from configuration normalization to the request
boundary because a provider no longer declares a loader kind.

`use_existing` adopts the referenced node's execution contract. `use_host`
uses its explicit host operation as its contract. These rules make behavior
independent of request order.

## Live host integration

The live adapter is the one boundary where loader-specific information is
unavoidable: DFHack exposes host `require` and `reqscript` operations rather
than a general source-file loader.

The core TestBed remains source-keyed and exposes no special public naming
scheme for DFHack-owned files. A live request follows this order:

1. Run the normal private searchers and generate ordinary consumer source
   candidates.
2. Select a matching user provider or readable consumer source using normal
   candidate precedence.
3. Only when nothing satisfies the request, allow the live adapter to borrow
   an approved foundational dependency from the DFHack host.
4. Record the discovered host filename as an internal canonical source
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
automatic foundational fallbacks. It replaces the loader-focused
`component_imports` field.

For example, production code continues to use an ordinary request:

```lua
local gui = require('gui')
```

A test can preempt the live fallback with an ordinary source target, even when
that consumer file does not exist:

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
implementation details and are not valid public provider targets. Explicit
`use_host` remains available when a normal consumer source target should be
satisfied by a deterministic host request.

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
- `mkmodule()` publishes immediately and continues to break supported circular
  module dependencies;
- annotated scripts publish their environment before execution and clear
  failed state for retry;
- `require('dfhack')` remains the reserved bed-local facade and cannot be
  redirected through `package.loaded`, preload, custom searchers, or a source
  provider;
- protected loader bindings and the `dfhack` facade cannot be replaced through
  ordinary source global writes; and
- close invalidates all retained loaders and clears graph-owned references.

The refactor intentionally changes these contracts:

- public provider identity changes from `(kind, name)` to a canonical
  source target;
- source-focused descriptors replace loader-specific descriptors;
- automatic foundational host modules change from provider-before-source
  precedence to fallback-after-consumer-source-and-provider precedence;
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
`kind`, `component_imports`, and `(kind, name)` registry are removed together.
Configuration using any legacy field is rejected with an error that identifies
the unsupported field and points to `providers` or
`component_host_fallbacks`, as appropriate.

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
   provider configuration.
2. Extend path resolution to return ordered canonical candidates without
   requiring that every candidate already exist.
3. Replace the split token registry with one source provider registry.
4. Introduce the source-node registry, alias maps, virtual-source support, and
   request-edge records.
5. Route private `require` and `reqscript` through source resolution before
   provider lookup, while binding `mkmodule` publication to the active
   source node.
6. Preserve mutable preload/searcher and public package-cache behavior around
   the new registry.
7. Add direct source loading and source-focused component descriptors.
8. Move script-result validation and incompatible-access errors to the source
   request boundary.
9. Adapt live host borrowing as a fallback after ordinary sources and
   providers without exposing host naming through the public API.
10. Track provider selection, create ordered unused-provider warning records,
    and perform their defined delivery attempts during close.
11. Remove the legacy token implementation and update declarations,
   documentation, fixtures, and diagnostics.

Each step must preserve deterministic close behavior and must not mutate the
process-wide `package.path`, `package.loaded`, or DFHack script cache.

## Verification

Focused unit coverage must prove:

- provider configuration accepts exactly one strategy and rejects missing or
  competing strategies, including `use_value=nil` as a missing strategy;
- lexically equivalent target paths produce one provider identity;
- two different logical module names resolving to one file share one source
  node and one result;
- module and script adapters resolving to one target consult the same
  provider; compatible protocol-neutral values are shared, while declared
  contract mismatches fail before execution;
- a provider can satisfy an otherwise missing first-precedence candidate;
- an earlier virtual candidate shadows a later real candidate;
- `?.lua` and `?/init.lua` candidates retain normal precedence;
- private `package.path` mutation affects new names without changing an
  already-cached name-to-source alias;
- relative private `package.path` templates resolve from the process current
  directory, while configured source references resolve from the consumer
  root;
- clearing or setting `false` through a known `package.loaded` alias performs
  the declared source-wide invalidation and re-resolution;
- a detached explicit `package.loaded` override survives invalidation through
  another alias to the same source;
- module `nil`, `false`, explicit publication, loader-data, and failed-retry
  behavior remains compatible;
- `mkmodule()` binds partial publication to the active source, supports
  circular imports, preserves distinct requesting-name and published-name
  results, and creates a virtual publication when no file source is active;
- mutable preload and custom searchers retain their order and produce stable
  bed-local virtual source identities;
- `use_source` isolates the provided source under the target identity;
- `use_existing` shares the referenced source identity;
- an unprimed `use_existing` lazily loads its target, applies the target's own
  strategy, and reports missing, self, and cyclic targets;
- provider and dependency cycles report canonical source chains;
- incompatible module/script access fails without executing a source twice;
- `use_value` is protocol-neutral but enforces table results at a script
  request boundary;
- `use_host` uses explicit operation/name metadata and is independent of alias
  or request order;
- direct loading exercises present and absent targets for every compatible
  provider strategy and rejects absent targets without a provider;
- filesystem-free canonicalization and candidate-resolution tests cover
  project-relative paths, normal absolute paths, Windows drive-absolute and UNC
  paths, rejected Windows drive-relative and device-namespace paths, and the
  declared platform case rules;
- standalone configuration remains independent from live-host support;
- the reserved `dfhack` facade and protected loader bindings cannot be
  intercepted by source providers;
- used providers create no warning record, while every unused user provider
  creates one record and receives the defined delivery attempt in declaration
  order on the first `close()`;
- provider selection marks the provider used before strategy execution, while
  candidate generation alone does not;
- selected `use_source` and `use_host` providers remain used, and therefore do
  not warn, when their compatibility checks or strategy execution fail;
- provider failures, lazy `use_existing`, preload/custom-searcher precedence,
  repeated `close()`, and an injected warning sink follow the warning contract;
- when a non-default warning sink fails, the failed record is attempted once on
  standard error, the sink is disabled, later records continue through standard
  error in declaration order, and graph cleanup remains complete; and
- closing a TestBed invalidates every retained source loader and request
  adapter.

Declaration fixtures must prove that source-targeted configurations and
descriptors type-check through `providers` and `component_host_fallbacks`,
while `imports`, `kind`, `provide`, and `component_imports` are rejected.

Focused live coverage must prove:

- source-focused descriptor mounts construct the intended component;
- source providers apply to transitive component dependencies;
- automatic foundational host fallbacks preserve real DFHack class identity;
- explicit host borrowing selects the appropriate host adapter;
- readable consumer module sources and ordinary source providers preempt
  automatic host fallback without special host-path syntax;
- `reqscript` requests never receive automatic foundational host fallback;
- file-backed and native/preloaded host identities remain internal;
- unused mount-owned providers warn after component destruction and unmounting
  when DwarfSpec closes the TestBed;
- separate mounts receive fresh source graphs; and
- unmount destroys the component before closing its mount-owned TestBed.

Full validation must include the existing unit suite, source-declaration
checks, Lua syntax checks, package verification, and the established live
TestBed automation set.

## Acceptance criteria

The refactor is complete only when:

- the direct source entry point is exactly `bed:load(source)`;
- public TestBed configuration uses `providers` with source `target` values and
  uses `component_host_fallbacks` for automatic foundational live borrowing;
- `imports`, `provide`, loader `kind`, and `component_imports` are removed
  immediately without a compatibility adapter;
- the core provider registry is keyed only by canonical source identity;
- request methods and logical names are stored as graph-edge metadata rather
  than source-node identity;
- one canonical lexical source cannot be silently executed twice under
  separate module and script caches;
- source-focused providers can satisfy both present and intentionally absent
  source candidates;
- `mkmodule`, private package tables, module cache-result rules, custom
  searchers, and failed-load retry behavior satisfy the compatibility policy;
- live host borrowing is deterministic and does not depend on the first
  request edge;
- ordinary source providers take precedence over automatic live host fallback,
  with no special public host-source naming convention;
- the first close creates one ordered warning record and makes the defined
  delivery attempt for every unused user-configured provider, including the
  specified sink fallback behavior, without interfering with cleanup;
- canonical source paths use deterministic ASCII case folding across the
  complete path on Windows and preserve case on other platforms;
- standalone and live behavior retain their documented ownership and cleanup
  guarantees;
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
- Every provider specifies exactly one strategy; `use_value=nil` counts as an
  omitted strategy and is invalid.
- Direct loading supports absent targets through the configured provider
  strategy and rejects an absent target without a provider.
- Custom-searcher results always use stable bed-local virtual identities and
  cannot declare file-backed source metadata.
- Path validation accepts project-relative and normal absolute paths, including
  Windows drive-absolute and UNC paths, while rejecting Windows drive-relative
  and device-namespace paths. Path tests remain filesystem-free.
