# Open branches

Every branch that is not merged into `main`, with what it is for. Remove a branch's line when it is fast-forwarded
into `main` or deleted; add a line when a branch is made. Each active branch has its own folder next to the main
checkout, `StatefulAlgorithms.jl-<name>` (listed when it has one). `backup/*` and `archive/*` branches are not listed:
they are snapshots, not work.

Updated 2026-11-04.

## Refactor stack

| Branch | Folder | On top of | Intent |
|---|---|---|---|
| `refactor/partitions` | `-partitions` | `main` | One partition system: `Partition{kind, name}` (`StatePartition`, `RuntimePartition`), no name turned into a partition; `Var` is an unresolved `VarLocation`; nsref/partref. Under review; plan-compiles and the others rebase onto it. |
| `refactor/plan-inputs` | `-plan-inputs` | `refactor/partitions` | Plan inputs as ordinary arguments: plans called like functions `(arg1, arg2, ...)`, inputs passed explicitly, header inputs as declared locals, `@input` removed. Design doc, and the registered input state (`IdentifiableAlgo{<:RuntimeInputState}`) already removed. |
| `refactor/contexts-processes-pausing` | `-contexts-processes-pausing` | `main` | The process/session split from `refactor/plan-compiles` rebuilt on `main`: sessions, `prepare_for_loop` and the `LoopContext` built there (the place where the plan's map is dropped once plan-compiles is rebased onto it; precompiles not included), the `InlineProcess` changes (inlined loop, no threaded or async path), and the pause design: a pause splits the `LoopContext`, the state synced into the process's `state_context` handle (`_sync_state_context!`), the runtime context in its own slot, combined again on resume; no `context(p, c)`; every process type checked. `refactor/plan-compiles` rebases onto it and `refactor/partitions` in one pass. |
| `refactor/plan-holds-no-data` | `-plan-holds-no-data` | `refactor/contexts-processes-pausing` | A plan holds no data (TODO.md, "A plan holds no data"): `LoopAlgorithm` keeps only plan, options and registry; the context and the `Init`/`Override` specs are kept by the user after `setup` or by the process (`state_context`, `specs`); plan-level `init(la, specs...)`, `partialinit` and `run(la)` removed in favour of `setup` / `run(plan, context)` / `reinit(plan, context, ...)`. Owner to review. |
| `refactor/plan-compiles` | `-plan-compiles` | `main` | Resolve and construction compile once per plan type, not per plan: untyped construction, endpoints found on values, the process/session redesign; the old id replacement. Generic work goes here. Rebases onto `refactor/partitions`. |
| `refactor/monolithic-resolve` | `-monolithic-resolve` | `refactor/plan-compiles` | Only the monolithic `Unique` id replacement (`replace_unique_ids`), no caches. |
| `exp/replace-ids-cache` | `-replace-ids-cache` | `refactor/monolithic-resolve` | Experiment: `replace_unique_ids` keeps its type walks in global caches. |
| `exp/resolve-cache` | `-resolve-cache` | `exp/replace-ids-cache` | Experiment: step 1 of resolve walks the plan's type at run time, its expression cached per type. |

## Fixes

| Branch | Folder | On top of | Intent |
|---|---|---|---|

## Experiments

| Branch | Folder | Intent |
|---|---|---|
| `exp/gen-full-resolve` | `-gen-full-resolve` | The id numbering worked out in the generated body per plan type, nothing in global caches. |
| `exp/generated-replace` | `-generated-replace` | `replace_unique_ids`' rebuild as one generated nested constructor. |
| `exp/inline-context-argument` | `-inline-context-argument` | `InlineSession` holds only the counter; an `InlineProcess` passes its context to the loop as an argument. |
| `exp/process-session` | | Process/session split and the parallel precompile of the manager (`precompile_interface`). |
| `exp/unique-plan-id` | `-unique` | `UniquePlanId`: a `Unique` handle's id as data, stripped at construction, numbered per plan. |
| `exp/unique-plan-id-cleanup` | `-cleanup` | Cleanup on top of `exp/unique-plan-id`: `Var` holds only its matcher, `reconstruct_var`. |
| `exp/ukm-in-registry` | `-ukm` | The `UniqueKeyMap` lives in the registry from resolve until the loop. |
| `exp/no-maybe` | `-nomaybe` | Declared locals without `Maybe`. |
| `exp/if-generated` | `-ifgen` | `@inline_generated`: the inline marker put into the generated code. |

## Features

| Branch | Folder | Intent |
|---|---|---|
| `refactor/plans` | `-plans` | One plan type: `CompositeAlgorithm` and `Routine` build a `Plan` with an interval or repeat entry per child; a step paused in the middle resumes where it stopped. |
| `feat/on-change` | `-onchange` | On-change handlers; a handler's return is its own value, routable like a captured return. Design doc. |
| `feature/cleanup-releasable` | `-cleanup-releasable` | Design only (TODO.md, "Cleanup and releasable state"), on top of `refactor/contexts-processes-pausing`; to implement later. Cleanup per algorithm releases what it holds at the plan's end of life and never changes the state's shape; releasable slots (a reference that can be released, marked by the algorithm or the user, allocated by the init); the finalizer (`@finally`) is the plan's one exit. |

## Older, status to check

Not touched since early October; possibly superseded by later work. Check each before using or deleting it.

| Branch | Last commit | Intent (from its commits) |
|---|---|---|
| `main-after-ff` | 2026-10-11 | Perf suite notes on main before `main` was reset to `b417371`. |
| `refactor/loopcontext` | 2026-10-06 | `LoopContext`/`InitContext` bundles; every plan node a scope. |
| `refactor/runtime` | 2026-10-06 | Context parts chosen by dispatch on a type. |
| `refactor/callable` | 2026-10-06 | `Callable` internal, moved to LoopAlgorithms. |
| `refactor/funcs-in-plan` | 2026-10-02 | `Executable` and `WithWiring` replace `FuncWrapper` in plans. |
| `refactor/scoping` | 2026-10-01 | `@let` / `@local` declarations in the DSL. |
| `fix/state-scoping` | 2026-10-09 | One TODO commit left after the state-scoping work was merged. |
| `feature/perf-work-cases` | 2026-10-01 | Work-heavy mirrors of the Process-overhead perf cases. |
| `perf/bootstrap-barrier` | 2026-09-27 | Ticks after the bootstrap step behind a `@noinline` barrier. |
| `perf/routine-inline-substep` | 2026-09-28 | Routine child schedule emitted inline. |
