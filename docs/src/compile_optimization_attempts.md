# Compile Optimization Attempts

This file records compile-latency experiments so failed paths are not repeated.

Some older entries below mention `TaskData`. That type has been removed from
the active lifecycle; those notes are retained as historical compile-latency
context only.

## Kept Changes

- Captured concrete loop algorithm types in helper signatures.
  This replaced several `Type{<:T}` method arguments with `Type{Concrete} where Concrete <: T` when the method reads the exact type.

- Added constructor-time `ProcessManager` precompile scheduling.
  The hook runs after manager construction and targets concrete manager, slot, and job types.

- Kept constructor-time `Process` loop precompile scheduling.
  This is close enough to the first `run` call to reduce first-run latency without
  precompiling broad `LoopAlgorithm` metadata paths too early. The precompile
  signature now targets the actual non-generated loop method:
  `loop(process, algo, context, lifetime, inputs, Resuming{false}, NonGenerated)`.
  The previous signature omitted `inputs` and `Resuming`, so it aimed at a
  wrapper shape that did not match the first-run call.

- Moved process loop precompile helpers to `ProcessPrecompile.jl` and removed
  lock/dedup task bookkeeping.
  The construction hook now schedules a plain best-effort precompile task, and
  first run no longer waits on or coordinates a global precompile task registry.
  This reduced nearby constructor overhead and made the profile easier to read.

- Added a narrow `SimpleAlgo(single_algorithm)` construction fast path.
  The common one-algorithm case now builds the simple `LoopAlgorithm` directly
  instead of going through the full `CompositeAlgorithm` parser and
  `flatten_comp_funcs`. `intervals(::SimpleAlgo)` still returns `Interval(1)`
  values so existing multiplier code sees the same shape.

- Reduced generation-time work in context constructors and merges.
  Generated helpers now use simple static loops instead of closure-based
  `all`/`filter`/`findfirst` scans, and `_merge_into_globals` constructs a
  `ProcessContext` directly instead of going through the generic `setfield`
  generated helper.

- Added single-name `SubContextView` location lookup for generated read and
  merge paths.
  Normal `getproperty(view, Val(name))`, `haskey(view, Val(name))`, and
  `stablemerge`/`unstablemerge` planning no longer build the full location
  table just to resolve one name. The full `get_all_locations` path remains for
  property enumeration and error reporting.

- Avoided empty process setup work.
  Empty input/override construction now skips a throwaway context build, and empty `initcontext` paths avoid vararg filtering.

- Moved `setfield` debug rendering out of generated-function generation.
  Large debug strings are now built only on the error path.

- Made input/override resolution require a resolved algorithm.
  `prepare_process_constructor` resolves the normalized algorithm before resolving
  inputs or overrides. `resolve_process_inputs_overrides` now reads the registry
  from that resolved algorithm and errors when called directly with an unresolved
  algorithm. This is mostly a contract cleanup; measured compile latency was
  neutral against the same benchmark using an already-resolved algorithm.

- Fused single-algorithm `resolve` registry build with algorithm keying.
  The single-argument path now uses the keyed algorithm returned while adding
  algorithms to the registry instead of building a registry and then doing a
  second registry lookup pass through `update_keys`. Multi-algorithm resolve
  still uses the shared-registry path.

- Bound concrete value argument types in the resolve/materialization helpers.
  Changing signatures such as `la::LoopAlgorithm` and
  `registry::NameSpaceRegistry` to `la::LA where LA<:LoopAlgorithm` and
  `registry::R where R<:NameSpaceRegistry` improved the full process benchmark
  after the fused resolve change. This is not only useful for `Type` arguments;
  it can help value arguments too.

- Added narrow lifecycle/input resolution fast paths.
  `init(la, Input(...), Override(...))` now resolves specs through typed methods
  for empty, already-named, and raw `Init`/`Override` tuples. Context
  construction receives the already-resolved lifecycle-stripped algorithm, so it
  does not resolve again. The public input/override resolver also has a typed
  all-`Input`/`Override` path while preserving the old generic fallback.

- Inlined only small setup-path accessors and wrappers that improved the simple
  compile benchmark.
  The retained inline hints are on the resolve preparation chain, lifecycle
  constructor helpers, input/override accessors, and generic `LoopAlgorithm`
  interface accessors.

- Kept the normal first-entry `Process` context on the concrete algorithm path.
  `Process.runtime_context` now starts as `nothing`; `makeloop!` reads the
  stored algorithm context for the first run and only falls back to
  `runtime_context` after external context replacement or a returned runtime
  context. This removes the `runtime_context::Any` leak from the first-entry
  loop path without changing the public `context(process)` behavior after a run.
  The runtime field itself is now `Union{Nothing, ProcessContext}` rather than
  `Any`, so resumed contexts are intentionally abstract only at the
  `ProcessContext` level.

- Kept concrete stored contexts on initialized `LoopAlgorithm` values.
  `CompositeAlgorithm` and `Routine` both store `context::C`, where `C` is a
  type parameter. For an initialized algorithm,
  `fieldtype(typeof(la), :context) === typeof(getstoredcontext(la))` holds, and
  the first-entry process path through `_typed_runtime_context(process)` infers
  the exact `ProcessContext{...}` type.

- Extended the PrecompileTools workload for the managed `@ProcessAlgorithm`
  normal `Process` path.
  The workload now covers `SimpleAlgo(_ProcessPrecompileManaged)`, typed
  `Input`/`Override` resolution, lifecycle `init(...; lifetime = Repeat(1))`,
  `Process(...)`, first run, and construction from an already initialized
  algorithm. This covers the package-side version of the compile benchmark's
  managed lifecycle path. It cannot remove compilation of user-defined
  `Main.@ProcessAlgorithm` generated methods, but it does precompile the
  package helper methods those generated algorithms call.

- Added narrow `@nospecialize` barriers on `Base.wait(::Process)` and
  `Base.fetch(::Process)`.
  These methods only touch `p.task` or `p.lastresult`, so they do not need a
  separate specialization for every full `Process{CompositeAlgorithm{...}}`
  type. A trace-compile pass on the simple TTFP script dropped from about `137`
  lines to about `116` lines after the exact loop precompile and wait/fetch
  barriers.

## Reverted Or Rejected

- `@nospecialize` on process precompile helpers.
  Julia accepts both formal-argument and statement-position `@nospecialize`, but the tested changes made latency noisier or worse.

- Generated location caching for subcontext views.
  The idea was to cache location computation in generated helpers. In the tested pattern it did not improve the target benchmark.

- Refactoring `stablemerge`/`unstablemerge` merge planning.
  Several versions using grouped plans and helper functions were neutral or slower.

- Structural helpers for `_global_context_type` and related loop precompile signatures.
  They passed tests but worsened construction/first-run latency.

- Reusing the input-resolution `ProcessContext` through a public `TaskData` keyword option.
  This avoided one duplicate context build, but introduced a new constructor specialization path and did not produce a stable win.

- Reusing the input-resolution `ProcessContext` through a narrow internal `Process` constructor path.
  This avoided one duplicate context build for `Process(algo, Input(...), Override(...))`, but did not improve the compile-latency benchmark. The first call is dominated by compilation of resolution, merge, init, and run paths; after compilation, warm process construction is already small enough that the saved context build is below benchmark noise. This was removed to keep the constructor path simpler.

- Splitting `TaskData` into a typed positional internal helper.
  This was meant to avoid keyword dispatch in `Process` construction. It increased cold-stage latency in the compile benchmark.

- Adding type parameters directly to the public `TaskData` keyword constructor.
  This also worsened compile-facing benchmark numbers and was reverted.

- Constructor-time `LoopAlgorithm` metadata precompile.
  Immediate scheduling made nearby construction and input-resolution stages
  contend with background compilation. Adding an arbitrary sleep moved the
  contention but did not reliably improve immediate time-to-first-process-run.
  The hook, lock, type set, delay constant, and metadata precompile helper were
  removed.

- Splitting `setup_registry` into an `add_loopalgorithm_to_registry` helper.
  Both a fully specialized helper and a variant with `@nospecialize` on the loop
  algorithm were tested. The split made cold construction/first-run latency worse
  and also hurt warmed process-loop timing, so the original single-body registry
  setup remains preferable.

- Adding a `@noinline` unresolved-resolve boundary.
  The goal was to stop `Process` construction from compiling through the full
  resolve path. In practice it made first-run and warmed process-loop timing
  worse, which suggests the resolved algorithm type information is still useful
  to the later loop path.

- Adding `Base.@constprop :none` to `setup_registry`.
  This was meant to reduce caller-side compile work without changing semantics,
  but it worsened warmed loop timing and was removed.

- Rewriting only `resolve(la::LoopAlgorithm)` as `resolve(la::LA) where
  {LA<:LoopAlgorithm}` before the fused resolve change.
  Isolated to the old resolve implementation, this did not improve the compile
  benchmark. After the fused single-resolve implementation, applying the pattern
  consistently to the resolve helper chain did improve the full process
  benchmark.

- Broad `@inline` pass over `Process` utility helpers.
  Inlining one-hop helpers around process state, runtime, precompile signatures,
  and loop scheduling did not improve direct time to first process run and made
  staged lifecycle/hot timings noisier, so it was reverted.

- Broad `@inline` pass over `CompositeAlgorithm` and `Routine` accessors.
  This worsened direct time to first process run substantially in the simple
  benchmark, with samples around `679 / 721 / 826 ms`, so it was reverted. The
  useful inline hints are much narrower.

- Adding the process context type as a second `Process{F,C}` parameter.
  This made first-entry context access infer, but it also made the process type
  larger and worsened direct time to first run. The retained version keeps
  `Process{F}` and reads the typed context from `getstoredcontext(getalgo(p))`
  while `runtime_context` is empty.

- Type-level replacement for `_global_context_type`.
  A generated helper computed the context type for `_merge_into_globals(context,
  (; process = p))` without doing the merge. It made staged `Process`
  construction slower, so the value-based implementation was restored.

- Stripping `:_input` and `:process` before storing a finished `Process`
  context.
  This kept the typed first-entry path available after completion, but it changed
  the public `context(process)` result. Existing runtime-input tests expect those
  transient entries to remain visible after `run`/`wait`, so the stripping was
  reverted for `Process`.

- Forcing `context(process)` to always return the stored loop algorithm context.
  This was tested as a temporary diagnostic to check whether the abstract
  `runtime_context` branch explained TTFP. It did not. With 8 Julia threads,
  direct time to first process run stayed at about `546-549 ms`, matching the
  restored getter. The patch was reverted.

- Async `resolve(typeof(la))` precompile immediately after loop algorithm
  construction.
  A narrow manual test still worsened direct TTFP: with an explicit wait it was
  about `560-569 ms`, and without waiting it was about `566-569 ms`, compared
  with a current baseline around `547-552 ms`. This confirms that resolve-time
  precompile is still too early for the immediate construct-and-run path.

- Disabling constructor loop precompile.
  This was neutral to slightly worse for direct TTFP and moved work from
  `Process` construction into first run. The constructor precompile remains
  useful, but only when it targets the exact loop signature.

- `@nospecialize` on `run!(::Process)`.
  This wrapper looked like an easy compile barrier, but it regressed direct TTFP
  to about `571-578 ms`, so it was reverted. `run!` should keep the concrete
  process type so the call into `run`/`makeloop!` remains well inferred.

## Current Benchmark Notes

- After the latest profiling pass on the simple managed `@ProcessAlgorithm`
  microbench with 8 Julia threads, direct construct-to-first-run timings were
  about `295 / 303 / 298 ms`. Before these local changes the same path was
  around `516-529 ms`; after only the `SimpleAlgo` fast path it was around
  `434-444 ms`.

- The main wins came from avoiding the full parser for single `SimpleAlgo`, not
  building full location tables for one-name view access/merge planning, and
  removing generic `setfield` from `_merge_into_globals`.

- `manual tests/ProcessHotLoopBenchmark.jl` checks normal hot-loop runtime.
  Recent larger runs did not show a normal `Process` hot-loop regression against clean `HEAD`.

- `manual tests/ProcessCompileLatencyBenchmark.jl` should break compile-facing
  work into algorithm construction, `resolve`, lifecycle `init`, `Process`
  constructor, first run, and warmed hot runs.

- `manual tests/ProcessResolveBenchmark.jl` measures fresh construction,
  `resolve`, already-resolved `resolve`, `initcontext`, `Process` construction,
  first run, and warmed fresh-resolve throughput for simple, routed, shared, and
  nested algorithms.

- The current benchmark should be refreshed against the lifecycle-init path.
  Metadata reuse should stay on narrow internal paths.

- Current lifecycle fast-path benchmark on 8 Julia threads:
  direct time to first process run is about `545-552 ms` across cold Julia
  processes after the lifecycle/input refactor and first-entry context cleanup.
  Temporarily bypassing `runtime_context` entirely did not improve this number.
  The staged compile benchmark still shows the cold cost mainly in algorithm
  construction, `Process` construction, and first run; warmed construction and
  warmed first run are small.

## LoopAlgorithm Stored Context Check

The initialized loop algorithm context is typed correctly. A small diagnostic
using a one-step `CompositeAlgorithm` showed:

- `typeof(la).parameters[6]` is the concrete stored context type.
- `fieldtype(typeof(la), :context) === typeof(getstoredcontext(la))`.
- `getstoredcontext(la)` infers the concrete `ProcessContext{...}`.
- `_typed_runtime_context(process)` infers the same concrete `ProcessContext{...}`
  before the process has stored a returned runtime context.

This means the remaining first-run compile cost is not caused by the stored
LoopAlgorithm context being abstract. The intentionally abstract point is only
the mutable `Process.runtime_context` after a runtime context has been stored or
externally replaced.

## SnoopCompile Pass

Ran a temporary-environment SnoopCompile pass with `SnoopCompileCore.@snoop_inference`
on the compile benchmark workload. The project dependency files were not changed.

Important exclusive inference-time signals from the small benchmark:

- `step!` generated by `@ProcessAlgorithm`: about `55 ms`.
- `get_all_locations(::Type{<:SubContextView})`: about `51 ms` accumulated.
- `Base.getproperty(::SubContextView, ::Val)`: about `44 ms` accumulated.
- `_merge_into_globals`: about `35 ms` accumulated.
- `merge_into_subcontext_rebuild`: about `28 ms` accumulated.
- `merge(::SubContextView, ::NamedTuple)`: about `25 ms`.
- `init` generated by `@ProcessAlgorithm`: about `25 ms`.
- `setup_registry`: about `19 ms`.

Important inclusive paths:

- `resolve(::CompositeAlgorithm)`: about `207 ms`, mostly through registry setup.
- `loop(::Process, ::CompositeAlgorithm, ::ProcessContext, ::Repeat, ::NonGenerated)`:
  about `122 ms`.
- legacy `initcontext(::TaskData{... inputs/overrides ...})`: about `92 ms`.
- `Process(...; repeats=1)`: about `87 ms`.

The pass also showed inference under background precompile tasks launched from
`Process.jl`. Future SnoopCompile runs should either disable those tasks or run a
separate pass specifically for the precompile pipeline, otherwise normal workload
inference and background precompile inference are mixed together.

## LoopAlgorithm Metadata Precompile

The first SnoopCompile pass showed background metadata precompile tasks mixed into
normal first-call inference. The compile benchmark confirmed this was not just a
measurement artifact: launching metadata precompile immediately from
`LoopAlgorithm` construction made the next constructor stages contend with those
tasks.

Measured cold-stage comparison on the simple compile benchmark:

- Immediate background precompile:
  `algo construction ~= 106 ms`, `input resolution ~= 118 ms`,
  `Process constructor ~= 63 ms`, `first run ~= 137 ms`.
- Disabled metadata precompile:
  `algo construction ~= 105 ms`, `input resolution ~= 30 ms`,
  `Process constructor ~= 61 ms`, `first run ~= 151 ms`.
- Delayed metadata precompile by `0.2s`:
  `algo construction ~= 106 ms`, `input resolution ~= 27 ms`,
  `Process constructor ~= 54 ms`, `first run ~= 141 ms`.

Later measurements showed the best immediate construct-to-first-run path came
from removing the `LoopAlgorithm` constructor metadata precompile entirely while
keeping the `Process` constructor loop precompile:

- No `LoopAlgorithm` metadata precompile:
  `algo construction ~= 87-90 ms`, `input resolution ~= 26-33 ms`,
  `Process constructor ~= 53-55 ms`, `first run ~= 123-134 ms`.

The conclusion is that metadata precompile from `LoopAlgorithm` construction is
too early for this workload. It either contends with input resolution or, when
delayed, is less useful for the immediate first run. The retained precompile path
is the `Process` constructor loop precompile, which is closer to the actual code
that will run.
