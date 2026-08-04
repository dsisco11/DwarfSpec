# Source-file-focused TestBed refactor proposal

## Status

This is a draft proposal for discussion. It defines a direction for the
TestBed model and public API. It does not authorize or describe a completed
implementation.

## Summary

Refactor TestBed so that a resolved source file is the primary identity of a
dependency. `require()` and `dfhack.reqscript()` remain supported ways for
production code to reach dependencies, but they become request adapters at the
edges of the TestBed graph. They no longer determine the identity used for
replacements, caching, aliases, or diagnostics. `mkmodule()` remains a
publication operation and binds a module name to the source that is currently
executing instead of resolving another source.

The current import form:

```lua
{
    provide={kind='module', name='my_plugin.clock'},
    use_value=MOCK_CLOCK,
}
```

would become source-focused:

```lua
{
    target='src/my_plugin/clock.lua',
    use_value=MOCK_CLOCK,
}
```

The replacement applies when any supported TestBed loader resolves a request
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

- Make the source file being replaced explicit in every user-configured
  import.
- Remove `kind` from ordinary TestBed import configuration.
- Make one canonical lexical source path one TestBed graph identity, even when
  multiple logical names can reach it.
- Allow `require()` and `reqscript()` to share replacement selection without
  erasing their production-compatible call behavior.
- Preserve `mkmodule()` as immediate publication of the currently executing
  source environment so circular module imports continue to work.
- Keep replacements deterministic when roots, `package.path`, or aliases
  produce multiple candidate files.
- Preserve the ability to replace a source that is intentionally absent from
  the test filesystem.
- Keep TestBed framework-neutral and usable without a live DFHack process.
- Preserve mount-scoped ownership and cleanup for live descriptor mounts.
- Produce diagnostics in terms of source paths, with request method and
  logical name included only as context.

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

Absolute paths remain supported for sources intentionally outside the
consumer project.

### Source identity

A source identity is TestBed's canonical internal filename. It uses an
absolute path, forward slashes, a normalized drive prefix on Windows, and
lexically normalized `.` and `..` segments. It does not use `realpath()` or
resolve symlinks.

This follows the existing TestBed path policy while making the normalized
filename the graph key. Symlinks, hard links, and path spellings that remain
distinct after the declared lexical normalization may still create distinct
source identities even when the filesystem ultimately reaches the same
physical file.

### Request edge

A request edge records how one source reached another source. It includes:

- the calling source identity;
- the operation, such as `require` or `reqscript`;
- the requested logical name; and
- the resolved target source identity.

The operation and logical name belong to the edge, not to the target's
identity.

### Replacement

A replacement is a test policy attached to a target source identity. It
selects one of the supported strategies: a value, another source file, a
shared existing source identity, or a value borrowed from the live host.

## Proposed public API

### Source-targeted imports

Retain the `imports` configuration field initially, but replace `provide` with
one required `target` source reference:

```lua
local MOCK_CLOCK = {
    now=function() return 42 end,
}

local bed = TestBed.new{
    imports={
        {
            target='src/my_plugin/clock.lua',
            use_value=MOCK_CLOCK,
        },
    },
}
```

Keeping `imports` limits the public rename surface while the identity model is
being corrected. Renaming the field to `replacements` can be considered
separately after the new semantics are accepted.

Every target is resolved relative to the effective consumer root when the
TestBed is constructed. Duplicate canonical targets are configuration errors,
including targets written with lexically equivalent paths.

### Replacement strategies

`use_value` continues to return the exact borrowed value:

```lua
{
    target='src/my_plugin/clock.lua',
    use_value=MOCK_CLOCK,
}
```

`use_source` executes a replacement file under the target source's graph
identity:

```lua
{
    target='src/my_plugin/storage.lua',
    use_source='tests/fakes/in_memory_storage.lua',
}
```

The replacement filename is not a second graph identity. If the same fake
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

The referenced source does not need to be loaded first. Its own replacement,
if any, is applied normally. An absent referenced source without a replacement
fails when the alias is first requested. Self-aliases and longer
`use_existing` cycles are errors reported with the complete source chain. The
request reaching the alias must be compatible with the referenced source's
execution contract.

Host borrowing remains live-only, but its core registry entry is attached to a
source identity instead of a module or script token. The replacement carries
explicit adapter metadata so its result does not depend on which request edge
happens to arrive first:

```lua
{
    target='src/my_plugin/platform.lua',
    use_host={operation='require', name='my_plugin.platform'},
}
```

`operation` is either `require` or `reqscript`. It describes how the
replacement value is obtained from DFHack; it is not part of the target source
identity. Because the metadata is explicit, direct source loading, aliases,
and repeated access all borrow the same deterministic host value. A request
whose execution contract is incompatible with the configured host operation
fails before the host loader is called.

### Direct source loading

Add a source-first entry point:

```lua
local controller = bed:load('src/my_plugin/controller.lua')
```

`bed:load(source)` resolves a source reference directly, applies any matching
replacement, and returns the source node's value. This becomes the preferred
entry point for new tests and source descriptors.

`bed:require(name)` and `bed:reqscript(name)` remain supported as compatibility
entry points and as the implementations bound into production source
environments. They resolve the requested name to a source identity before
loading it.

The final method name (`load`, `load_source`, or another spelling) remains an
API naming decision. This proposal uses `load` for readability.

### Source-focused component descriptors

Live component descriptors should identify their source directly:

```lua
ds.mount({
    source='src/my_plugin/save_panel.lua',
    export='SavePanel',
}, {
    title='Saved value',
}, {
    imports={
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
candidate that either exists as a readable file or has a configured
replacement. A replacement therefore acts as a virtual source file and can
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
Custom searcher results receive bed-local virtual identities containing the
searcher identity, request name, and bounded loader data. These identities are
diagnostic and cache keys; they are not valid public import targets. A custom
searcher may opt into a file-backed identity by returning documented TestBed
source metadata with its loader.

The private `package.preload` and `package.searchers` tables remain mutable and
authoritative. Their ordering is preserved. Source-targeted replacement lookup
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
searchers or replacements are consulted, while the reserved `dfhack` facade
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

A source replacement supplied with `use_source` must have an execution
contract compatible with the target. When the target exists, TestBed can
compare their declarations before execution. When the target is absent, the
replacement source declaration establishes the contract.

`use_value` has no declared execution contract. It is valid through a module
request with any non-`nil` value and through a script request only when its
value is a table. The first request does not permanently classify the value;
later compatible requests to the same target reuse the same value. Script-table
validation therefore moves from configuration normalization to the request
boundary because an import no longer declares a loader kind.

`use_existing` adopts the referenced node's execution contract. `use_host`
uses its explicit host operation as its contract. These rules make behavior
independent of request order.

## Live host integration

The live adapter is the one boundary where loader-specific information is
unavoidable: DFHack exposes host `require` and `reqscript` operations rather
than a general source-file loader.

The core TestBed must still remain source-keyed. The live adapter will:

1. resolve automatic foundational host imports to canonical host source
   identities when possible;
2. create an exact request binding that injects the host source candidate ahead
   of consumer candidates for the automatic foundational request;
3. register deterministic host operation/name metadata against that source
   identity; and
4. call the configured host loader when the host source node is loaded.

Preloaded or native host modules may not have a discoverable source file. They
require an explicit virtual host-source identity. Such identities are an
exception confined to the live adapter and must not reintroduce `(kind, name)`
as the core graph key.

The automatic component imports (`class`, `utils`, `gui`, `gui.widgets`, and
`gui.dwarfmode`) continue to preserve host identity and their current
request-level precedence. Their request bindings are live-adapter metadata,
not core source identities.

Live configuration accepts a stable host-root-relative source reference for a
user replacement. This proposal uses `@host/` as the provisional spelling:

```lua
{
    target='@host/lua/gui.lua',
    use_value=MOCK_GUI,
}
```

The live adapter resolves `@host/` against the active DFHack installation and
canonicalizes the result. A user replacement for that canonical host source
takes precedence over the synthesized host borrow policy while retaining the
same automatic request binding. Standalone TestBeds reject `@host/` targets.

Non-file host dependencies use a stable public live-only virtual reference:

```lua
{
    target='@host/virtual/require/native_api',
    use_value=MOCK_NATIVE_API,
}
```

The operation segment is `require` or `reqscript`; the final path segment is a
canonical encoding of the complete logical name. Encode the logical name's
UTF-8 bytes by leaving only ASCII letters, digits, `_`, and `-` unchanged and
writing every other byte as an uppercase `%HH` escape. Encode the empty name as
the reserved segment `~`; a literal `~` is `%7E`. The decoder rejects lowercase
or malformed escapes, escapes that decode to the literal safe set
`[A-Za-z0-9_-]`, and any bare `~` that is not the complete empty-name segment.
It never treats the decoded value as a path. This makes the encoding
reversible, canonical, collision-free, and safe for names containing `/`, `.`,
`..`, `%`, empty segments, or non-ASCII characters.

This representation is used only when the live adapter cannot discover a
file-backed host identity. It gives automatic native or preloaded host
bindings the same user-replacement precedence as file-backed host sources
without returning the core registry to loader-token identity.

The exact host-root layout and final prefix spelling must be verified against
the supported DFHack installation before implementation, but public
configuration must not require machine-specific absolute host paths.

## Configuration and path behavior

The effective consumer root remains:

- the current process directory for standalone TestBeds; and
- the active DwarfSpec project root for live descriptor mounts.

`module_roots` and `script_roots` continue to define how existing production
requests produce candidate source files. They no longer partition replacement
identity.

Relative `target`, `use_source`, `use_existing`, and direct `load()` paths all
resolve from the same effective consumer root. Absolute paths remain accepted.

Lexical normalization must make these references identical:

```text
src/my_plugin/clock.lua
./src/my_plugin/clock.lua
src/my_plugin/../my_plugin/clock.lua
```

Windows path comparison must also normalize separator and drive-letter case.
Whether the remainder of a Windows path is compared case-sensitively must be
decided and tested explicitly; it must not depend accidentally on Lua table
key spelling.

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
  replacement;
- protected loader bindings and the `dfhack` facade cannot be replaced through
  ordinary source global writes; and
- close invalidates all retained loaders and clears graph-owned references.

The refactor intentionally changes these contracts:

- public replacement identity changes from `(kind, name)` to a canonical
  source target;
- source-focused descriptors replace loader-specific descriptors;
- incompatible access to a declared module or script source fails rather than
  creating a second identity; and
- explicit invalidation through a known `package.loaded` alias invalidates the
  shared source generation and its other aliases.

All other behavioral changes require an explicit amendment to this proposal.

## Migration

The new import form is not mechanically equivalent to every old token import.
A legacy `(kind, name)` can resolve differently after private `package.path`
mutation, can refer to a provider-only dependency with no discoverable file,
and can intentionally distinguish module and script namespaces for the same
name.

For that reason, the core should not silently translate legacy tokens and
claim source-focused semantics. Two migration approaches are viable:

1. Make this an explicit breaking configuration change and reject `provide`.
2. Provide a temporary legacy adapter that retains the old token registry
   outside the new source graph and emits deprecation diagnostics.

The first option is cleaner and is recommended unless compatibility policy
requires a transition period. If a legacy adapter is required, new and legacy
forms must not be mixed in one TestBed configuration.

The refactor also updates:

- public LuaLS declarations;
- descriptor validation and overload declarations;
- unit and live fixtures;
- the technical TestBed reference;
- the end-user TestBed wiki page; and
- error messages and loader-data diagnostics.

## Implementation outline

1. Introduce an immutable canonical `SourceId` value and source-targeted
   replacement configuration.
2. Extend path resolution to return ordered canonical candidates without
   requiring that every candidate already exist.
3. Replace the split provider registry with one source replacement registry.
4. Introduce the source-node registry, alias maps, virtual-source support, and
   request-edge records.
5. Route private `require` and `reqscript` through source resolution before
   replacement lookup, while binding `mkmodule` publication to the active
   source node.
6. Preserve mutable preload/searcher and public package-cache behavior around
   the new registry.
7. Add direct source loading and source-focused component descriptors.
8. Move script-result validation and incompatible-access errors to the source
   request boundary.
9. Adapt live host borrowing and automatic component imports without exposing
   loader tokens to the core registry.
10. Remove or isolate the legacy token implementation according to the chosen
   migration policy.
11. Update declarations, documentation, fixtures, and diagnostics.

Each step must preserve deterministic close behavior and must not mutate the
process-wide `package.path`, `package.loaded`, or DFHack script cache.

## Verification

Focused unit coverage must prove:

- lexically equivalent target paths produce one replacement identity;
- two different logical module names resolving to one file share one source
  node and one result;
- module and script adapters resolving to one target consult the same
  replacement; compatible protocol-neutral values are shared, while declared
  contract mismatches fail before execution;
- a replacement can satisfy an otherwise missing first-precedence candidate;
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
- `use_source` isolates the replacement under the target identity;
- `use_existing` shares the referenced source identity;
- an unprimed `use_existing` lazily loads its target, applies the target's own
  strategy, and reports missing, self, and cyclic targets;
- replacement and dependency cycles report canonical source chains;
- incompatible module/script access fails without executing a source twice;
- `use_value` is protocol-neutral but enforces table results at a script
  request boundary;
- `use_host` uses explicit operation/name metadata and is independent of alias
  or request order;
- direct loading exercises present and absent targets for every compatible
  replacement strategy;
- Windows and Unix path normalization follow the declared identity rules;
- standalone configuration remains independent from live-host support;
- the reserved `dfhack` facade and protected loader bindings cannot be
  intercepted by source replacements; and
- closing a TestBed invalidates every retained source loader and request
  adapter.

Declaration fixtures must prove that source-targeted configurations and
descriptors type-check while legacy `kind`/`provide` forms fail or are marked
deprecated according to the selected migration policy.

Focused live coverage must prove:

- source-focused descriptor mounts construct the intended component;
- source replacements apply to transitive component dependencies;
- automatic foundational host imports preserve real DFHack class identity;
- explicit host borrowing selects the appropriate host adapter;
- automatic host request bindings inject deterministic canonical host source
  candidates and accept user replacement of that same source identity;
- both file-backed and native/preloaded automatic host sources have stable
  public replacement references;
- virtual host references round-trip empty, separator-containing, escaped, and
  non-ASCII logical names without collisions, and reject lowercase, malformed,
  or over-escaped forms such as `%41`;
- separate mounts receive fresh source graphs; and
- unmount destroys the component before closing its mount-owned TestBed.

Full validation must include the existing unit suite, source-declaration
checks, Lua syntax checks, package verification, and the established live
TestBed automation set.

## Acceptance criteria

The refactor is complete only when:

- no ordinary public TestBed import requires a loader `kind`;
- the core replacement registry is keyed only by canonical source identity;
- request methods and logical names are stored as graph-edge metadata rather
  than source-node identity;
- one canonical lexical source cannot be silently executed twice under
  separate module and script caches;
- source-focused imports can replace both present and intentionally absent
  source candidates;
- `mkmodule`, private package tables, module cache-result rules, custom
  searchers, and failed-load retry behavior satisfy the compatibility policy;
- live host borrowing is deterministic and does not depend on the first
  request edge;
- standalone and live behavior retain their documented ownership and cleanup
  guarantees;
- public declarations, technical documentation, and the wiki describe the
  source-file model consistently; and
- all required focused, full, declaration, package, and live checks pass.

## Open decisions

The following decisions should be resolved before converting this proposal
into an implementation checklist. Acceptance requires recording their answers
in this document and removing the corresponding open items:

1. Is `load` the right name for the direct source entry point, or should it be
   `load_source`?
2. Should `imports` be retained, or renamed to `replacements` in the same
   breaking change?
3. Should legacy token imports be rejected immediately or supported through a
   temporary, explicitly separate adapter?
4. Is `@host/` the correct spelling and root model for portable public DFHack
   host source references?
5. Should Windows source identity compare the full path case-insensitively?
