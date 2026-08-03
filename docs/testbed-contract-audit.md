# TestBed contract audit

This record maps the proposal's prototype acceptance criteria to production
ownership, focused regression coverage, and the evidence gate that proves the
claim. File names are repository-relative. Final commands and results are
recorded in `docs/testbed-implementation.todo`.

| # | Acceptance criterion | Implementation | Focused evidence | Gate |
|---:|---|---|---|---|
| 1 | Zero-config conventional module and annotated script loading | `testbed.lua`, `testbed/internal.lua`, `testbed/config.lua` | `testbed/testbed_spec.lua`: zero-configuration child | Offline consumer fixture |
| 2 | Canonical configuration/provider types and optional loader data | `testbed.lua`, `ds.d.lua` | declaration fixtures and package-state loader-data cases | Source declarations and Lua 5.4 unit |
| 3 | TestBed config appears only on tagged descriptor overloads | `ds.d.lua` | valid and invalid declaration fixtures | Source declarations |
| 4 | Ordinary class mounts remain two-argument and allocate no bed | mount command/context | ordinary success and failure allocation spy | Focused mount and full unit |
| 5 | Component instances are rejected | mount command and descriptor/context validation | command instance rejection and descriptor export cases | Focused mount |
| 6 | Every descriptor mount owns one fresh bed, including defaults | mount context and TestBed adapter | omitted/explicit config, consecutive mount, and close-count cases | Focused mount and live freshness |
| 7 | Logical descriptors resolve construction without physical paths | mount descriptor/context | module/script descriptor and empty-name cases | Focused mount and live configured descriptor |
| 8 | Constructor options and TestBed config remain separate | mount command/context | overlapping-field collision case | Focused mount |
| 9 | Optional fields, root replacement, and component-import disablement | `testbed/config.lua`, mount adapter | optional/root and adapter disablement cases | Focused core and adapter |
| 10 | All provider strategies and invalid shapes | config and package/script loaders | provider-shape matrix and provider resolution cases | Focused core and declarations |
| 11 | The module token `dfhack` is reserved for every strategy | config and package state | reserved-token provider matrix | Focused core |
| 12 | User providers override synthesized providers and providers beat source | config merge and package/script resolution | adapter override and source-precedence cases | Focused core and adapter |
| 13 | Host providers are live-only and borrowed; aliases preserve identity | config and package/script loaders | standalone rejection, exact host-loader, and alias cases | Focused core and adapter |
| 14 | Native plugins can be borrowed, faked, or source-shimmed | provider resolution and live importer | plugin strategy case | Focused core |
| 15 | Standard/live base bindings are construction snapshots | base environment and live adapter | standard-binding and live snapshot cases | Focused core and adapter |
| 16 | Globals replace ordinary bindings and `globals.dfhack` is complete | config and base environment | configured-global and complete-facade cases | Focused core |
| 17 | `dfhack`, `BASE_G`, and reserved writes preserve one protected facade | base environment and package state | facade identity/protection cases | Focused core |
| 18 | Mutable package mechanisms cannot redirect reserved `dfhack` | package state and base environment | private-package `dfhack` identity case | Focused core |
| 19 | Framework-neutral require succeeds without DFHack globals | public TestBed entry point | no-DFHack entry-point case | Focused core and offline consumer fixture |
| 20 | Framework-neutral require reaches no live, driver, ds, or Busted module | public TestBed and core internals | dependency-boundary and adapter non-load cases | Focused core |
| 21 | Production modules remain under `src`; fixtures remain outside it | repository layout | fixture-integrity and entry-point tests | Syntax and repository audit |
| 22 | Two beds do not share module state | package state and TestBed constructor | stateful package and public graph cases | Focused core |
| 23 | Nested dependencies remain in one graph and see replacements | package state | nested-source and configured-provider cases | Focused core and live configured descriptor |
| 24 | Process package state stays unchanged except normal TestBed imports | private package state | entry-point boundary and package-state ownership cases | Focused core and fixture-integrity guard |
| 25 | Private package tables and search mechanisms are mutable and authoritative | package state | cache/preload/searcher/path replacement cases | Focused core |
| 26 | Native Lua cache, return, false, and loader-data behavior | package state | nil, false, published, override, and loader-data cases | Lua 5.4 unit |
| 27 | Native `cpath` and `loadlib` are unavailable | package state | private package ownership case | Focused core |
| 28 | Host reload and script-environment sentinels never run | base environment reserved policy | live snapshot and published-policy cases | Focused core |
| 29 | Dynamic loaders use the owning environment and preserve results | module environment | default/explicit environment, error, and multiple-return cases | Focused core |
| 30 | Every versioned reserved loader field is installed or rejected | base environment policy | published-policy completeness case | Focused core |
| 31 | Delegated live command APIs remain host effects | live adapter/base snapshot | consumer-root and live-facade case | Focused adapter and user isolation matrix |
| 32 | `mkmodule` publishes stable partial state and stays fresh per bed | package state | `mkmodule` stability, publication, and isolation case | Focused core |
| 33 | Unpublished module cycles are bounded; published cycles pass | package state | published-cycle and bounded-failure cases | Focused core |
| 34 | Success/failure clear active state and failed modules can retry | package state | marker cleanup and retry cases | Focused core |
| 35 | `bed:reqscript` and `dfhack.reqscript` share one environment | package state and script loader | annotated-script identity cases | Focused core |
| 36 | Source scripts receive only the modern module guard | script loader | annotated loading, provider, legacy, and retry cases | Focused core |
| 37 | Missing modern annotations fail before execution | script loader | invalid-script case | Focused core |
| 38 | Legacy `moduleMode` is rejected clearly | script loader | legacy-annotation case | Focused core |
| 39 | Circular scripts share preallocated environments privately | package state and script loader | circular-script cases | Focused core |
| 40 | Script aliases preserve identity; alias-only cycles are bounded | script loader | provider-alias and alias-only-cycle cases | Focused core |
| 41 | Script failures clear preallocated and active state for retry | script loader | failed annotated-script retry case | Focused core |
| 42 | Two beds do not share script globals | package state and public TestBed | script isolation and standalone graph cases | Focused core |
| 43 | Module `_G` is local and cannot reach process `_G` | module environment | direct and `_G`-qualified write case | Focused core |
| 44 | Resolution failures and cycles have bounded actionable chains | paths, package state, and script loader | missing-candidate and bounded-chain cases | Focused core |
| 45 | Undeclared live host modules fail | live adapter and config | synthesized-module allowlist case | Focused adapter |
| 46 | Exact host providers retain mount-compatible DFHack identities | live adapter | exact host-loader case | Focused adapter and live configured descriptor |
| 47 | Component providers exist before its defining source loads | mount context and live adapter | descriptor resolution-order cases | Focused mount and live configured descriptor |
| 48 | Root and explicit-path resolution makes no containment promise | config and paths | consumer-root and explicit-path cases | Focused core |
| 49 | Checked-in consumer fixture uses active source and consumer files | public TestBed entry point and fixture tree | zero-config child and fixture-integrity guard | Offline consumer fixture |
| 50 | Production-style widget uses module/script dependencies and host providers | descriptor mount and live adapter | live consumer fixture | Live configured descriptor |
| 51 | Consecutive live mounts have fresh state and clean ownership | descriptor mount lifecycle | consecutive mount unit case | Live freshness and cleanup |
| 52 | Constructor failure closes the bed and leaves the host usable | mount ownership/unwind | exact constructor-failure close-count case | Live constructor failure and cleanup |
| 53 | Close invalidates owned loaders but not returned values | TestBed, package state, and environments | public graph-through-close case | Focused core |
| 54 | No process-global active-bed registry exists | instance-owned underscored state and mount ownership | private-field and consecutive-mount cases | Focused core, mount, and repository search |

## Representative consumer comparison

The checked-in `consumer.lua` fixture loads an ordinary module and annotated
script. Without TestBed, a test that replaces both dependencies must save and
rewrite two process-global caches, account for every transitive module, arrange
script-environment state, and restore all entries on both success and failure.
It must repeat that surgery to prove fresh state.

With TestBed, the test declares two exact providers, loads the unchanged
consumer through `bed:require`, and closes one owned graph. The replacement and
cleanup boundary is explicit in the configuration, while the integrity guard
proves the process loaders, working directory, and checked-in fixture tree are
unchanged. The live descriptor form adds mount ownership so component teardown
precedes graph release. This materially reduces setup and cleanup without
claiming rollback for borrowed or native effects.
