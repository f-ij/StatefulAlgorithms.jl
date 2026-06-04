# Immutable Context / Widened Field Diagnostics

This folder tracks the `immutable_fix` branch experiment around removing the
old first-step widening merge path while keeping immutable `ProcessContext`
updates specialized.

## Current Experiment

The branch keeps `ProcessContext` immutable and adds a typed widened bucket:

```julia
ProcessContext{D, Reg, R, I, W}
```

`W` is the type of `_widened`. This is deliberately concrete. An earlier
`_widened::Any` version was invalid for performance: it made route-heavy
execution allocate hundreds of MB per run.

The intended semantics are:

- normal route/local/shared writes still merge into typed subcontexts;
- returned fields that are not part of the current subcontext/view shape merge
  into `_widened`;
- `_widened` remains available to later routed reads inside the same loop step;
- after the loop finishes, `_widened` is materialized into subcontexts for the
  public result and stripped back to the stored context shape.

The goal is to remove the old unstable first-step shape change from the hot loop
without losing concrete typing for shape-widening returns.

## Important Files

- `src/Context/StructDefs.jl`
  Defines `ProcessContext{D, Reg, R, I, W}`.
- `src/Context/ProcessContexts.jl`
  Implements `withwidened`, `merge_into_widened`, and
  `materialize_widened_context`.
- `src/Context/View/Locations.jl`
  Keeps normal subcontext reads direct, but falls back to `_widened` for routed
  fields that do not exist in the subcontext data.
- `src/LoopAlgorithms/RuntimeInputs.jl`
  Restores `_widened` to the stored/empty shape when runtime-only data is
  stripped.

## Benchmarks To Run

From the repository root:

```sh
julia --startup-file=no --project=. diagnostics/immutable_fix/run_benchmarks.jl
```

This runs:

- `diagnostics/inline_route_heavy_benchmark.jl`
- `diagnostics/inline_scalar_dependency_probe.jl`

Manual commands:

```sh
INLINE_ROUTE_HEAVY_RUNS=5 INLINE_ROUTE_HEAVY_STEPS=20000 julia --startup-file=no --project=. diagnostics/inline_route_heavy_benchmark.jl
SCALAR_DEPENDENCY_STEPS=100000 SCALAR_DEPENDENCY_TRIALS=100 julia --startup-file=no --project=. diagnostics/inline_scalar_dependency_probe.jl
```

## Correctness Checks

```sh
julia --startup-file=no --project=. diagnostics/immutable_fix/run_checks.jl
```

Manual commands:

```sh
julia --startup-file=no --project=. -e 'using Test, StatefulAlgorithms; include("test/CompositeDSLTest.jl")'
julia --startup-file=no --project=. -e 'using Test, StatefulAlgorithms; include("test/RuntimeInputsLifecycleTest.jl")'
julia --startup-file=no --project=. -e 'using Test, StatefulAlgorithms; include("test/ContextInjectorTest.jl")'
```

Current status:

- `CompositeDSLTest.jl` passes.
- `RuntimeInputsLifecycleTest.jl` has one expected behavior change: the old
  second shape widening error no longer throws, because widened fields are now
  accepted into `_widened`.
- `ContextInjectorTest.jl` still fails the interactive ref update checks after
  removing the unstable first-step behavior. This needs design attention before
  the branch is mergeable.

## Current Measurements

### Latest Run After Current `ProcessContexts.jl` Fix

Command:

```sh
julia --startup-file=no --project=. diagnostics/immutable_fix/run_benchmarks.jl
```

Results:

```text
inline_route_heavy_steps=20000
inline_route_heavy_runs=5
inline_route_run_seconds_per_run=0.002466292
plain_loop_seconds_per_run=0.002791842
seconds_ratio=0.883
inline_route_run_bytes_per_run=0.0
```

The second route-heavy runtime benchmark is more important for this branch. It
was added because the five-stage route-heavy benchmark did not expose the
write-then-read/shared-state slowdown. Latest run:

```text
scalar_dependency_steps=100000
scalar_dependency_trials=100
reset_alloc=512
run_alloc=0
direct_loop_alloc=0
generated_processloop_alloc=0
direct_plan_alloc=0
run_seconds=0.052136042
direct_loop_seconds=0.046973375
generated_processloop_seconds=0.046406084
direct_plan_seconds=0.055237167
plain_seconds=0.008740334
run_ratio=5.965
direct_loop_ratio=5.374
generated_processloop_ratio=5.309
direct_plan_ratio=6.320
```

So the simple route-heavy benchmark is not sufficient. The dependency-heavy
probe still shows a serious runtime slowdown even without allocations.

### Earlier Concrete-Widened Signal

After making `_widened` concrete and keeping normal routed reads direct:

```text
inline_route_heavy_steps=20000
inline_route_heavy_runs=5
inline_route_run_seconds_per_run=0.001867117
plain_loop_seconds_per_run=0.001989867
seconds_ratio=0.938
inline_route_run_bytes_per_run=0.0
```

These numbers are process-noisy. The useful qualitative result is:

- `_widened::Any` was catastrophic and must not be used;
- concrete `_widened` restores zero allocations on the route-heavy benchmark;
- the dependency-heavy route benchmark still exposes a serious runtime slowdown
  despite zero allocations.

## Failed Intermediate Shape

Do not reintroduce this:

```julia
_widened::Any
```

That version measured roughly:

```text
inline_route_run_seconds_per_run=0.315135267
plain_loop_seconds_per_run=0.002203817
seconds_ratio=142.995
inline_route_run_bytes_per_run=311042288.0
```

After making `_widened` concrete but routing every known read through widened
checks, route-heavy performance was still unstable. The current version avoids
that by reading normal known fields directly from `get_subcontexts(context)` and
only consulting `_widened` when a requested routed field is absent.
