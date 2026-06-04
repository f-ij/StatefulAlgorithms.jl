# Performance optimization opportunities

This document lists semantics-preserving optimization ideas for `StatefulAlgorithms.jl`.
It separates actual implementation ideas from validation work, benchmark notes,
and things to avoid.

The current context/view/merge design is already shaped for Julia's optimizer:
generated code, concrete `NamedTuple` types, aggressive inlining, and stable
post-bootstrap context types. Treat these paths as SROA-friendly unless a
specific benchmark, `@allocated`, Cthulhu/JET trace, or `@code_llvm` result
proves otherwise.

A standalone probe script is available at
`benchmarks/performance_hypotheses.jl`:

```sh
julia --project=. benchmarks/performance_hypotheses.jl
```

Smoke run note: with `PROCESSES_BENCH_TRIALS=1`,
`PROCESSES_BENCH_REPEATS=100`, and
`PROCESSES_BENCH_CONSTRUCTION_TRIALS=2`, the direct post-bootstrap stable routed
step reported `0 bytes` allocated for both the stable and late-growth graph
probes.

## Optimization ideas

### 1. Replace interval-counter modulo with a branch

Relevant files:

- `src/LoopAlgorithms/CompositeAlgorithms.jl`
- `src/Threaded/CompositeAlgorithms.jl`
- `src/Packaging/Interface.jl`

The `inc!` methods compute a type-known LCM and update a `Ref` with `mod1`.
For tight loops, this can be slower than a simple branch:

```julia
cainc[] = cainc[] == LCM ? 1 : cainc[] + 1
```

This preserves the same counter sequence. Benchmark mixed intervals and
non-power-of-two intervals, since LLVM may already optimize some modulo cases
well.

### 2. Reconsider interval-counter storage

Relevant files:

- `src/LoopAlgorithms/CompositeAlgorithms.jl`
- `src/Threaded/CompositeAlgorithms.jl`

`inc::Base.RefValue{Int}` may add an indirection in hot composite loops. A
mutable field or a tiny typed counter object could be faster.

This needs a semantics check first: if sharing the `Ref` across copied/rebuilt
algorithm values is observable or relied on, keep the current representation.

### 3. Expose generated versus non-generated loop selection

Relevant files:

- `src/AbstractTypeDefs.jl`
- `src/Loops.jl`
- `src/GeneratedCode/GeneratedLoops.jl`

`sys_looptype` currently defaults to `NonGenerated()`, while generated loop
implementations still exist. A user-facing or preference-backed selector could
let workloads choose between first-run latency and steady-state speed.

Possible policy:

- `Generated()` for small stable inline graphs where fully inlined code wins.
- `NonGenerated()` for large graphs where compile time and code size dominate.
- An `:auto` mode based on graph size and route count.

### 4. Add a graph-size threshold for generated loop bodies

Relevant files:

- `src/LoopAlgorithms/GeneratedStep.jl`
- `src/GeneratedCode/GeneratedLoops.jl`
- `src/LoopAlgorithms/Step.jl`

Generated loops can become large for large composites/routines. A thresholded
strategy could keep full inlining for small graphs and emit grouped calls for
large graphs.

The goal is to reduce compile time and code size without changing execution
order or route semantics.

### 5. Avoid duplicate registry/context construction during process setup

Relevant files:

- `src/ConstructorCommon.jl`
- `src/TaskDatas.jl`
- `src/Context/Constructor.jl`

`prepare_process_constructor` builds an empty `ProcessContext(func)` to resolve
inputs/overrides. `TaskData` then resolves the algorithm and builds another
empty context. Resolve once, build registry/shared route state once, and reuse
that data for both input/override resolution and `TaskData`.

This targets constructor latency and repeated short-run workloads.

### 6. Cache a finalized/prepared algorithm representation

Relevant files:

- `src/LoopAlgorithms/FinalizedAlgorithm.jl`
- `src/LoopAlgorithms/Preparation`
- `src/Packaging`

For repeated construction from the same graph, expose or expand a finalized form
containing:

- resolved algorithm
- registry
- resolved options/routes/shares
- empty context shape
- pre-resolved input/override mapping metadata

The existing `Process(algo, ...)` API can stay unchanged; this can be an opt-in
fast path.

### 7. Reduce tuple-concatenation churn in constructors

Relevant files:

- `src/LoopAlgorithms/Setup.jl`
- `src/LoopAlgorithms/CompositeDSL.jl`
- `src/Unroll.jl`

Several setup paths build tuples incrementally with `(old..., new)` or collect
through `Any[]` before creating typed runtime objects. For large DSL-generated
graphs, this setup work can dominate.

Use temporary vectors or builders during parsing/lowering, then convert once to
the final typed tuple shape.

### 8. Avoid `deepcopy` in registry inheritance

Relevant file:

- `src/Registry/Registries.jl`

`inherit(registry1, registry2, multiplier)` deep-copies entries before scaling
multipliers. If the only goal is to avoid mutating `registry2`, rebuild entries
with copied/scaled multiplier vectors instead of deep-copying all entry data.

Validate that inherited registries do not share mutable multiplier vectors and
that key/name behavior remains unchanged.

### 9. Use `PreferStrongKeyDict` for dynamic registry lookup

Relevant files:

- `src/Registry/PreferStrongKeyDict.jl`
- `src/Registry/TypeEntries/StructDef.jl`
- `src/Registry/TypeEntries/Methods.jl`

`RegistryTypeEntry` stores `dynamic_lookup::Dict{Any,Int}`. The repository
already has `PreferStrongKeyDict`, which separates strong keys for isbits values
from weak-key handling. Use it if it preserves `match_by` behavior and improves
dynamic lookup/setup cases.

### 10. Parameterize `Process` storage where lifecycle paths need it

Relevant files:

- `src/Process.jl`
- `src/TaskDatas.jl`
- `src/ProcessInteraction.jl`

The steady-state loop receives typed `func`, `context`, and `lifetime`
arguments, so abstract `Process` fields are not automatically a loop problem.
They can still affect `run`, `close`, `fetch`, restart-heavy workloads, and code
that reads `process` through globals inside a step.

Possible change: add a more-parametric process representation for prepared
context/lifetime while keeping task/result/error fields flexible.

### 11. Add a fast typed `ProcessManager` mode

Relevant file:

- `src/Manager/ProcessManager.jl`

`WorkerSlot` stores `job`, `scratch`, `result`, and `error` as `Any`, which is
appropriate for the generic manager. A typed manager/slot variant could improve
many-small-job scheduling while preserving the current generic fallback.

Possible API: a recipe trait or constructor that fixes job, scratch, and result
types.

### 12. Parameterize `TimedProcess.callback`

Relevant file:

- `src/TimedProcess.jl`

`callback::Function` forces dynamic dispatch through the callback field. A
`TimedProcess{TD,C,CB}` representation can store the closure type concretely.
This should improve inference around timer setup and callback invocation without
changing behavior.

### 13. Add a persistent worker mode for threaded graphs

Relevant files:

- `src/Threaded/Step.jl`

`ThreadedCompositeAlgorithm` spawns tasks for children. For small per-child work,
task overhead can dominate. A
persistent worker or reusable task-pool mode could preserve dependency ordering
while avoiding fresh task scheduling for every child on every step.

### 14. Add a serial fallback for small threaded layers

Relevant files:

- `src/Threaded/Step.jl`

If a layer has too little work or only one runnable child, executing serially can
beat spawning. Add a configurable or static threshold while preserving the same
dependency layers.

### 15. Cache worker graph scheduling metadata

Relevant files:

- `src/Threaded/Step.jl`

Layer/graph specs are currently generated from types. Runtime overhead should be
low, but compile latency can grow with graph size. Store graph metadata in a
resolved/finalized algorithm representation and generate smaller code from that
metadata when first-run latency matters.

### 16. Re-enable a small PrecompileTools workload

Relevant file:

- `src/StatefulAlgorithms.jl`

`PrecompileTools` is loaded, but the workload block is commented. Add a small
representative workload covering:

- `Process` construction for a two-node composite
- `InlineProcess` construction and run
- one routed composite
- one routine
- one packaged/finalized algorithm if considered public API

Keep the workload small; broad precompile coverage can increase package
precompile time and cache size.

### 17. Move documentation-only dependencies out of runtime deps

Relevant file:

- `Project.toml`

`Documenter` is in main `[deps]`. If runtime code does not need it, keep it only
in `docs/Project.toml`. This reduces the dependency surface and load/precompile
work.

Also check whether `JLD2` must be imported at top level or can be loaded only by
save/load paths.

### 18. Split legacy/development macro utilities out of the main load path

Relevant file:

- `src/Functions.jl`

This file is large and includes `eval`, `Meta.parse`, and broad macro helpers.
If some helpers are legacy or development-only, move them behind a smaller
include boundary or a separate extension-like path.

Where helpers remain public, prefer direct `Expr` construction over
string-generation plus `Meta.parse`.

### 19. Add performance diagnostics for first-step context growth

Relevant files:

- `src/GeneratedCode/SubContextView.jl`
- `src/Context/ProcessContexts.jl`
- `manual tests/FirstStepContextChangeBenchmark.jl`

The unstable bootstrap step is part of the design. For performance-critical
loops, provide diagnostics that show variables introduced only after the first
step and recommend declaring steady-state output fields in `init`.

This does not change semantics, but it helps users choose the faster stable
context shape.

### 20. Add typed/batched interactive update queues

Relevant file:

- `src/Interactive/Injector.jl`

`ContextInjector` uses `Any[]` because interactive updates can be heterogeneous.
If interactive update throughput becomes important, add typed queues by target
variable or batch buffered updates into typed tuples before stepping.

Keep the current simple path for normal interactive use.

### 21. Add direct no-update step fast paths where missing

Relevant files:

- `src/Identifiable/Step.jl`
- `src/GeneratedCode/SubContextView.jl`
- `src/LoopAlgorithms/Step.jl`

Many algorithms return `nothing` or an empty `NamedTuple`. Ensure every generated
and non-generated step path preserves the cheapest possible handling for "no
context update": no merge work beyond the already-inlined `nothing` branch, and
no unnecessary construction of empty merge tuples.

### 22. Specialize route-transform call paths

Relevant files:

- `src/Context/View/Locations.jl`
- `src/RoutingInterface/RouteDef.jl`

Transformed routes are read through generated `VarLocation` accessors. Confirm
that transforms are held in a type-stable way and called directly after
inlining. If any transform path falls back to dynamic function calls, move the
transform into the type/domain where the getter can inline it.

### 23. Add a public performance profile for user algorithms

Relevant docs/tests:

- `docs/src/user/algorithms_states.md`
- `docs/src/user/init_analysis.md`
- `manual tests/FirstStepContextChangeBenchmark.jl`

Document and test the fast-path contract for user algorithms:

- declare steady-state fields in `init`
- return `nothing` or `(; )` for no updates
- keep returned `NamedTuple` names and value types stable
- mutate large arrays in place when appropriate
- keep route transforms type-stable and inlineable

This is an optimization of user-facing performance behavior rather than core
runtime code.

## Validation plan

Use the benchmark script and existing manual benchmarks to measure:

- package load time
- constructor latency
- first `run` latency
- steady-state per-step runtime
- post-warmup allocations
- generated-code size and compile latency

Existing useful targets:

- `benchmarks/performance_hypotheses.jl`
- `manual tests/FirstStepContextChangeBenchmark.jl`
- `manual tests/MergeHeavyBenchmark.jl`
- `manual tests/InterestingGraphBenchmark.jl`
- `test/InlineBenchmarkTest.jl`

Suggested tools:

- `BenchmarkTools.@benchmark` with interpolation
- `@allocated` after warmup
- `@code_warntype` on `run`, `loop`, `step!`, and `close`
- `@code_llvm debuginfo=:none` for SROA checks
- Cthulhu.jl for inference barriers
- JET.jl for type-instability reports
- SnoopCompile.jl for invalidations and precompile workload design

## Do not do without proof

- Do not remove `@inline` from hot paths as a style cleanup.
- Do not replace generated `NamedTuple` merge code with generic traversal unless
  LLVM and benchmarks improve.
- Do not assume context merge allocates just because the source constructs new
  values; verify SROA.
- Do not optimize away per-iteration `shouldrun`, tick, or pause behavior unless
  the public semantics are explicitly narrowed or an opt-in mode is added.
- Do not turn setup-time improvements into runtime type instability.
