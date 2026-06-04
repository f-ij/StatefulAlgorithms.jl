# Inline Route-Heavy Diagnostics Findings

Date: 2026-05-30

## Scope

This note records the route-heavy inline-process benchmark work and the follow-up
allocation/SROA investigation. The active diagnostic files are:

- `diagnostics/inline_route_heavy_benchmark.jl`
- `diagnostics/inline_route_heavy_breakdown.jl`
- `diagnostics/inline_route_type_stability.jl`
- `diagnostics/inline_scalar_dependency_probe.jl`

The benchmark target is intentionally real route-heavy scalar work: five
`ProcessAlgorithm`s (`sensor`, `filter`, `controller`, `plant`, `audit`) with
cross-algorithm routed dependencies, plus a plain scalar loop that performs the
same semantic work.

## Main Conclusions

Type-preserving routed writes currently do not allocate in the measured hot
loops. That is a narrow statement: it does **not** by itself prove stack
allocation or scalar replacement.

Several context representations were tested. The mutable `SubContext` approach
made same-type writes cheap to compile and fast for medium route-heavy work, but
it gives up the possibility that tiny scalar subcontexts are fully inline/isbits
inside the top-level context. The all-immutable Accessors approach improved the
tiny scalar shape, but it triggered pathological first-call LLVM/codegen latency
in the InteractiveIsing free-phase probe.

The active direction is therefore all-immutable context wrappers with a
package-local rebuild helper instead of Accessors. `replace_namedtuple_field`
rebuilds one named-tuple field, and `withdata`, `withruntime`, and
`withsubcontexts` rebuild the specific StatefulAlgorithms context objects. This keeps
immutability and avoids the generic Accessors lens/reconstruction machinery.

The remaining tiny-scalar performance problem is exactly the SROA/stack-local
problem. An ad hoc two-algorithm scalar replace probe performs no fresh
allocation in the loop, but is still about `6.5x` slower than an equivalent
plain scalar loop at 100k steps. That means "allocation-free" is insufficient:
the scalar values are not behaving like compiler-promoted local variables.
Pointer indirection through heap-backed subcontexts plus view/step/context
machinery dominates when each algorithm only updates a couple of scalar fields.

The checked-in Fib/Luc list-push benchmark is different. It is still close to
the naive loop in the current run, around `1.05x` to `1.11x` depending on
sample. That benchmark is dominated by vector mutation/push work and does not
isolate the tiny scalar replace/SROA case.

## Chronology

### Route-Heavy Benchmark

Added `inline_route_heavy_benchmark.jl` with:

- five real `ProcessAlgorithm`s
- route-heavy dependencies between those algorithms
- a semantic plain scalar loop baseline
- correctness checks against the plain loop
- end-to-end timing from `run(process)` to completion
- reset between samples, with reset excluded from the timed expression

Initial route-heavy measurements were roughly `1.9x` to `2x` slower than the
plain scalar loop.

### Breakdown Diagnostic

Added `inline_route_heavy_breakdown.jl` to isolate layers:

- `run(process)`
- direct `StatefulAlgorithms.loop(...)`
- generated process-loop entrypoint
- direct manual `ProcessContext` loop using `merge_into_subcontexts`
- diagnostic-only batched context loop
- direct `_step!` plan loop

The key observation was that the manual context loop was still near the routed
runtime cost, while the batched context loop was near plain-loop speed. The
batched loop is not generally valid, because later algorithms in the same loop
must see earlier context mutations, but it isolated the cost to repeated
per-child context writeback.

### Type Stability

Added `inline_route_type_stability.jl`.

`run(process)` was initially type-unstable because the keyword arguments
`context` and `lifetime` were reassigned after starting as `nothing`. That made
the public run return type infer as `Any`.

The fix in `src/InlineProcess.jl` binds separate locals:

- `run_context`
- `run_lifetime`

Current inference diagnostic:

```text
public_run_inferred=true
direct_loop_inferred=true
generated_processloop_inferred=true
direct_plan_inferred=true
```

## Merge Writeback Investigation

The `merge_into_subcontexts` hot path was not heap-allocating, but the immutable
subcontext implementation still caused aggregate copying. LLVM showed repeated
copies of the full `subcontexts` aggregate when rebuilding one field.

Two early changes were made in `src/Context/ProcessContexts.jl`:

- `merge_into_subcontext_rebuild` now binds `old_subcontexts = get_subcontexts(pc)`
  once before reading unchanged fields.
- Type-preserving `merge_into_subcontext_mutate` now mutates only the target
  subcontext's `data` field.

`SubContext` was temporarily changed from immutable to mutable in
`src/Context/StructDefs.jl`, and `newdata` used `setfield!`.

Important tradeoff: this removes aggregate rebuild traffic for type-preserving
stable writes, but subcontexts are now heap-backed objects rather than inline
isbits fields inside the context named tuple. Therefore this cannot preserve the
old tiny-scalar SROA behavior by construction.

Follow-up: `ProcessContext` itself was switched back to immutable while keeping
`SubContext` mutable. This matches the actual hot write path better:
type-preserving child writes mutate only the target `SubContext.data` field and
do not need to mutate the top-level `ProcessContext` wrapper at all. The
previous mutable `ProcessContext` line is left commented beside the immutable
definition for easy comparison.

A second experiment made both `ProcessContext` and `SubContext` immutable and
used Accessors.jl `@set` to rebuild immutable structures. Initially,
`SubContext{Name,T}` needed a custom reconstruction hook because Accessors /
ConstructionBase reconstructed `SubContext` as `SubContext(data)` and lost the
`Name` type parameter.

The better follow-up was to remove the duplicated `Name` type parameter from
`SubContext`. The subcontext key is already present in the enclosing
`ProcessContext` named tuple and in `SubContextView{...,SubName}`. `SubContext`
now stores `name::Symbol` as a value field and keeps only `data::T` in the type.
That makes `@set sc.data = new_data` work directly with default reconstruction,
while preserving typed payloads and the user-facing key via `getkey(sc)`.

Current source keeps `SubContext{T}` immutable with `name::Symbol`, but does not
use Accessors on the active path. Same-type subcontext updates now do:

```julia
new_subcontext = withdata(subcontext, new_data)
new_subcontexts = replace_namedtuple_field(old_subcontexts, Val(name), new_subcontext)
return withsubcontexts(pc, new_subcontexts)
```

The old mutable `setfield!` path remains only as comments for comparison.

## Allocation Results

Measured allocation facts after the mutable `SubContext` change and the
`_strip_runtime_inputs` shortcut:

Route-heavy component probe:

```text
merge_inputs_b = 0
before_b = 0
cleanup_b = 0
strip_b = 0
store_b = 0
unstable_step_b = 0
stable_step_b = 0
after_b = 0
```

Route-heavy benchmark, current sample:

```text
inline_route_heavy_steps=20000
inline_route_heavy_runs=20
inline_route_run_seconds_per_run=0.001562606
plain_loop_seconds_per_run=0.001528365
seconds_ratio=1.022
inline_route_run_bytes_per_run=0.0
plain_loop_bytes_per_run=10.4
```

Before the `_strip_runtime_inputs` shortcut, `run(process)` and direct loop
entrypoints still allocated about `240` bytes/run. Component probing showed all
of that came from `_strip_runtime_inputs(runtime_context, stored_context)`
rebuilding a fresh `ProcessContext` during `after_while`.

The shortcut now returns the existing runtime context when runtime globals,
runtime inputs, and legacy `:_input` storage are already unchanged. The previous
rebuild expression is left commented beside the new branch so it is easy to
restore for comparison.

Reset/construction allocation changed across the context representation
experiments. Examples observed:

- mutable `SubContext`: tiny scalar reset was about `176` bytes, and
  dependency/top-state reset was about `1848` bytes
- immutable `ProcessContext` with mutable `SubContext`: dependency/top-state
  reset dropped to about `760` bytes
- all-immutable `SubContext{T}` with `name::Symbol`: tiny scalar reset is `0`
  bytes in the current scalar replace probe, and dependency/top-state reset is
  about `512` bytes

The hot run path is still allocation-free in the measured inline benchmarks.
After switching the active path to package-local immutable rebuild helpers, the
route-heavy benchmark at `20_000` steps and `5` runs measured:

```text
inline_route_run_seconds_per_run=0.002236909
plain_loop_seconds_per_run=0.002176383
seconds_ratio=1.028
inline_route_run_bytes_per_run=0.0
plain_loop_bytes_per_run=41.6
```

## Checked-In Fib/Luc Benchmark

`test/InlineBenchmarkTest.jl` currently reports the inline Fib/Luc list-push
benchmark close to the naive list-push loop:

```text
InlineProcess time: 0.000427917 s
NoGen time:        0.000426209 s
Naive time:        0.000405166 s
Inline/Naive:      105.62 %
NoGen/Naive:       105.19 %
```

Separate direct runs also sampled around `109 %` to `112 %` of naive. This
benchmark therefore does not show the severe scalar-regression behavior.

## Route-Heavy Dependency And Top-State Probe

Added `inline_scalar_dependency_probe.jl` to cover a case the original
route-heavy benchmark did not isolate well: writes that are read by later
algorithms inside the same loop iteration, plus writes merged into the
top-level composite state.

The probe uses five `ProcessAlgorithm`s:

- `DependencySource`
- `DependencyMid`
- `DependencySink`
- `DependencyTopState`
- `DependencyFeedback`

The shape is intentionally small but route-heavy:

- a few scalar fields on each child
- small preallocated `Vector{Float64}` buffers on source/mid/sink/feedback
- top-level `_state` fields `top_signal`, `top_metric`, and `top_buffer`
- source writes read by mid in the same iteration
- mid/source writes read by sink in the same iteration
- sink/source writes merged into top-level `_state`
- freshly merged top-level state read by feedback in the same iteration
- feedback writes merged back into source-owned shared state

Current result at `100_000` steps and `100` trials:

```text
reset_alloc = 512
run_alloc = 0
direct_loop_alloc = 0
generated_processloop_alloc = 0
direct_plan_alloc = 0
run_seconds = 0.006085208
direct_loop_seconds = 0.006072750
generated_processloop_seconds = 0.006078875
direct_plan_seconds = 0.009892083
plain_seconds = 0.006100166
run_ratio = 0.998
direct_loop_ratio = 0.996
generated_processloop_ratio = 0.997
direct_plan_ratio = 1.622
```

Interpretation:

- The hot loop remains allocation-free for all measured entrypoints.
- `run`, direct `loop`, generated process-loop, and direct plan are close to
  each other with mutable `ProcessContext`; after switching `ProcessContext`
  back to immutable, the real `run`/loop/generated paths remain close, while
  the diagnostic direct-plan path is slower.
- The remaining cost is still the routed/context step path itself.
- In the all-immutable Accessors experiment, this dependency-heavy benchmark is
  effectively at parity with the equivalent local-variable loop on the real
  `run`/loop/generated paths.

Ad hoc inference checks for this probe returned concrete `ProcessContext`
types for `run`, direct `loop`, generated process-loop, and direct plan.

## Ad Hoc Tiny Scalar Replace Probe

A focused scalar replace probe used two tiny process algorithms:

- `ScalarFib`: `(; prev::Int64, curr::Int64)`
- `ScalarLuc`: `(; prev::Int64, curr::Int64)`

Each step replaces two scalar fields in each subcontext. This is the tiny SROA
case; unlike the checked-in Fib/Luc list-push benchmark, there is almost no real
work to hide context access/writeback overhead.

Current result at `100_000` steps:

```text
reset_b = 0
merge_b = 464
stable_step_b = 288
strip_b = 0
after_b = 0
run_b = 0
plan_b = 0
run_t = 0.000080917
plan_t = 0.000047334
plain_t = 0.000031875
run_ratio = 2.539
plan_ratio = 1.485
```

Interpretation:

- The static literal child merge remains allocation-free, but this diagnostic's
  compatibility-oriented dynamic merge probe reports allocation in the
  all-immutable version.
- Public `run` adds no measurable allocation after the strip shortcut.
- Direct plan timing is much closer to the plain scalar loop in the
  all-immutable version.
- Moving the subcontext name from the type parameter to a value field improved
  public `run` substantially in this tiny scalar case, from around `10x` to
  about `2.5x` over plain.

This means mutable subcontexts are not causing fresh per-step heap allocation,
but they also cannot give the old "fully stack/SROA everything" behavior for
tiny scalar contexts, because the subcontext object itself is a heap object. For
this benchmark, the relevant regression is not allocation count; it is the loss
of scalar replacement and the extra pointer/load/store path.

In the all-immutable Accessors experiment, the tiny direct-plan path improves
substantially, suggesting LLVM can optimize the immutable rebuild in that narrow
call shape. Removing `Name` from the `SubContext` type also helps the normal
public run path, although it is still not plain-loop speed.

## Interactive Caveat For All-Immutable SubContexts

The full test suite under all-immutable `SubContext` passed everything except
two `InteractiveVar` assertions:

```text
StatefulAlgorithms | 682 passed, 2 failed
```

Both failures are in `InteractiveVar writes through ContextInjector`. This is
expected for the experiment: `InteractiveVar` stores an old `ProcessContext`
value and previously observed later writes because mutable `SubContext` objects
were updated in place. With immutable subcontexts, the injector step returns a
new context value, and the old `InteractiveVar` still points at the old context.
The core inline/process tests otherwise passed.

## Previous Commit Comparison

The scalar replace probe was run against the committed optimized code and the
previous commit using a detached worktree rather than commenting code in/out.

Current commit:

```text
commit = da5f10e Potential performance updates
reset_alloc = 176
merge_alloc = 0
stable_step_alloc = 0
run_alloc = 0
direct_plan_alloc = 0
run_seconds = 0.000206542
direct_plan_seconds = 0.000206542
plain_seconds = 0.000031500
run_ratio = 6.557
direct_plan_ratio = 6.557
```

Previous commit:

```text
commit = f0c294a Manager updates
reset_alloc = 128
merge_alloc = 0
stable_step_alloc = 0
run_alloc = 208
direct_plan_alloc = 0
run_seconds = 0.000517625
direct_plan_seconds = 0.000516833
plain_seconds = 0.000031916
run_ratio = 16.218
direct_plan_ratio = 16.194
```

So the current commit improves this scalar replace probe substantially and
removes the fixed public `run` allocation, but it is still far from the
near-plain scalar behavior we want. The old near-identical scalar Fib/Luc result
must have been from an earlier commit or a different loop shape than the current
plain `ProcessAlgorithm` replace path.

## Process Loop Entrypoint

The generated process-loop entrypoint was tested in the breakdown diagnostic.
It is type-stable and allocation-free, but it did not materially change the
overall route-heavy story. In the route-heavy case, generated/direct/public
loop timings are close enough that the dominant cost is the child context
access/writeback path, not the public `run` wrapper.

Breakdown timings are noisy when run concurrently with other Julia processes,
so the stable facts to carry forward are:

- generated process loop is inferred
- generated process loop is allocation-free
- generated process loop is not a fix for the tiny scalar overhead

## Current Risk

The mutable `SubContext` fix is good for medium route-heavy scalar work because
it removes repeated aggregate rebuild traffic, but it is risky for very small
scalar-only algorithms because the heap-backed subcontext representation and
abstraction overhead can dominate the actual work.

If a workload creates/resets processes frequently, mutable subcontexts can be
worse because reset/construction allocate one object per subcontext. If a
workload reuses a process for many loop steps, that allocation is amortized and
the hot loop remains allocation-free.

The all-immutable Accessors fix is risky in the other direction: it can recover
better scalar behavior, but the InteractiveIsing free-phase probe showed
pathological first-call LLVM/codegen latency after the Accessors-based context
rebuild commit. Manual immutable rebuilds avoid the Accessors dependency and are
the current compromise under test.

## Immutable Rebuild Trial

I also tested switching `SubContext` back to immutable while keeping the
`old_subcontexts = get_subcontexts(pc)` binding and rebuilding/replacing the
full `subcontexts` named tuple on type-preserving writes.

That does not recover the scalar behavior either:

```text
route-heavy seconds_ratio = 1.461
scalar replace run_ratio = 16.012
scalar replace plan_ratio = 16.010
```

So the simple immutable rebuild path is worse for both targets in the current
code. The original near-naive Fib/Luc behavior must have come from a different
fast path/shape than "immutable subcontext plus full named-tuple rebuild on each
write".

## Open Performance Question

The next target is not heap allocation. The next target is lowering CPU overhead
for tiny scalar subcontexts while preserving the requirement that later
algorithms in the same iteration see earlier context mutations.

Possible directions to test:

- a generated scalar-local loop for fully static inline processes, where
  context fields are cached into locals and written back after each child as
  needed
- a hybrid context representation that keeps immutable/isbits subcontexts for
  small type-preserving scalar writes and uses mutable cells only where aggregate
  copying is more expensive
- a specialized stable writeback path that avoids `SubContextView`/generic
  context access for simple local replacements

The batched-context loop remains only a diagnostic lower bound. It cannot be the
general implementation because it hides mutations from later algorithms in the
same loop iteration.
