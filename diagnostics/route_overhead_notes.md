# Route Overhead Notes

This file records the route transparency optimization work and benchmark
observations. The benchmark target files are left as-is:

- `diagnostics/route_transparency_diagnostic.jl`
- `diagnostics/route_buffer_compat_benchmark.jl`

## Highest-Impact Changes

The biggest win was fixing `FuncWrapper` return routing. State outputs from
DSL wrappers were being written into runtime globals even when their names
already resolved to routed/shared state in the wrapper view. Routing those
returns through `stablemerge`/`unstablemerge` cut full diagnostic allocation
from about `2.98 MB/run` to about `1.3 KB/run`, and moved the full routed
target from about `2.98x` bespoke time to about `1.4x`.

The next useful change was making composite and routine stepping emit direct
generated child calls, while reusing stored child wiring. That removed a layer
of generic `unrollreplace`/callback dispatch from route-heavy hot paths and
brought the full diagnostic into the roughly `1.1x` to `1.2x` range on stable
larger runs.

A smaller but real win was splitting empty-wiring and routed-wiring `_step!`
methods, and avoiding the `contextview = nothing` pattern in identified
algorithm stepping. This mattered most for the manual routed-buffer benchmark,
where the remaining cost is mostly view construction plus type-preserving
writeback.

The experiments that did not help were also informative: positional view
construction, direct `stablemerge` generation inside subcontext merging, and a
repeat-1 `Routine` fast path were all slower or neutral and were reverted.

## Baseline Observations

Default `route_transparency_diagnostic.jl` before optimization:

- routed: about `0.000767548` seconds/run
- bespoke: about `0.000257679` seconds/run
- ratio: about `2.98x`
- routed allocation: about `2_977_300` bytes/run
- bespoke allocation: about `1_444` bytes/run

Default `route_buffer_compat_benchmark.jl` before optimization:

- routed: about `0.000373976` seconds/run
- bespoke: about `0.000200050` seconds/run
- ratio: about `1.87x`
- routed allocation: about `1_028` bytes/run
- bespoke allocation: about `1_284` bytes/run

The compatibility benchmark showed that ordinary identified algorithms with
routed buffer writeback were already allocation-light. The large allocation
problem was therefore not the loop-algorithm barrier itself.

## Breakdown Diagnostic

Added `diagnostics/route_overhead_breakdown.jl` to separate:

- manual identified routed-buffer algorithms
- macro-generated routed-buffer algorithms without `@context` or `@merge`
- state-buffer routines with `@context` and `@merge`
- state-buffer routines with `@context` but without `@merge`
- full route transparency target
- bespoke buffer loop

Before the first optimization, the breakdown showed:

- manual routed buffers: about `1 KB/run`
- macro routed buffers without merge: about `384 bytes/run`
- merged state-buffer routines: about `1.15 MB/run`
- context-only state-buffer routines: about `1.63 MB/run`
- full diagnostic: about `2.98 MB/run`

That pointed at DSL `FuncWrapper` state-output handling, not route lookup or
ordinary identified algorithm writeback.

## Optimization 1: FuncWrapper Return Routing

Changed `src/Widgets/FuncWrapper.jl`.

Previously every `FuncWrapper` return was merged into `ProcessContext._runtime`
through `merge_runtime_return`, even when the output name already resolved to a
local, routed, or shared variable in the wrapper's `SubContextView`.

That meant state assignments such as:

```julia
merge_buffer = diagnostic_merge_buffer!(merge_buffer, ...)
```

mutated the state buffer in place and then also wrote the returned
`merge_buffer` into runtime globals every step. Those runtime globals were
later stripped, so final semantics looked correct while the hot loop paid for
useless named-tuple growth/merges.

Added `merge_funcwrapper_return(...)`, a generated merge splitter:

- output names that resolve in the view merge through `stablemerge` or
  `unstablemerge`
- genuinely new output names still merge into runtime globals

After this change:

- `merge_state_buffer_only` allocation dropped from about `1.15 MB/run` to
  about `80 bytes/run`
- `context_state_buffer_no_merge` allocation dropped from about `1.63 MB/run`
  to about `288 bytes/run`
- full diagnostic allocation dropped from about `2.98 MB/run` to about
  `1.3 KB/run`

The target `route_transparency_diagnostic.jl` improved to:

- routed: about `0.000370767` seconds/run
- bespoke: about `0.000263058` seconds/run
- ratio: about `1.41x`
- routed allocation: about `1_300` bytes/run

## Optimization 2: Generated Composite Step Experiment

Changed `src/LoopAlgorithms/Step.jl`.

The file already contained a generated `CompositeAlgorithm` `_step!`
implementation as a commented experiment. I enabled it in place of the
`unrollreplace_withargs` implementation to test whether the remaining runtime
gap is caused by generic composite stepping overhead.

After this change:

`route_buffer_compat_benchmark.jl`:

- routed: about `0.000241553` seconds/run
- bespoke: about `0.000199096` seconds/run
- ratio: about `1.21x`
- allocation stayed about `1_028` bytes/run

`route_transparency_diagnostic.jl`:

- routed: about `0.000353798` seconds/run
- bespoke: about `0.000259164` seconds/run
- ratio: about `1.36x`
- allocation stayed about `1_300` bytes/run

This suggests the general composite stepping wrapper was a meaningful part of
the runtime overhead for route-heavy composites, while the first optimization
handled the large allocation issue.

Breakdown after both optimizations:

- manual routed buffers: about `0.000325` seconds/run, about `1 KB/run`
- macro routed buffers without merge: about `0.000233` seconds/run, about
  `384 bytes/run`
- merged state-buffer routines: about `0.000062` seconds/run, about
  `80 bytes/run`
- context-only state-buffer routines: about `0.000063` seconds/run, about
  `288 bytes/run`
- full route transparency: about `0.000381` seconds/run, about `1.3 KB/run`
- bespoke buffers: about `0.000256` seconds/run, about `1.4 KB/run`

The remaining full-diagnostic time appears additive: routed-buffer work plus
three state-buffer wrapper routines.

## Optimization 3: Direct Multi-Subcontext Merge

Changed `src/Context/ProcessContexts.jl`.

`merge_into_subcontexts(pc, args)` had a fast path for one target subcontext.
For multiple target subcontexts it built a tuple of one-entry named tuples with
`separate_nested_namedtuples(args)` and recursively called
`merge_into_subcontexts` through `unrollreplace`.

Routed writeback often updates multiple subcontexts in one return, for example
local mirror fields plus routed plant buffers. I replaced the recursive
multi-target path with generated straight-line calls to
`merge_into_subcontext(...)` for each target in field order.

After this change:

`route_buffer_compat_benchmark.jl`:

- routed: about `0.000234585` seconds/run
- bespoke: about `0.000204287` seconds/run
- ratio: about `1.15x`
- allocation stayed about `1_028` bytes/run

`route_transparency_diagnostic.jl`:

- routed: about `0.000327185` seconds/run
- bespoke: about `0.000254358` seconds/run
- ratio: about `1.29x`
- allocation stayed about `1_300` bytes/run

## Optimization 4: Generated Routine Step Experiment

Changed `src/LoopAlgorithms/Step.jl`.

Applied the same straight-line generated stepping approach to `Routine`.
Instead of stepping children through `unrollreplace_withargs` and an anonymous
callback, `_step!(::Routine, ...)` now emits one direct
`_subroutine_step!(...)` call per child.

After this change:

`route_buffer_compat_benchmark.jl`:

- routed: about `0.000235865` seconds/run
- bespoke: about `0.000206026` seconds/run
- ratio: about `1.15x`
- allocation stayed about `1_028` bytes/run

`route_transparency_diagnostic.jl`:

- routed: about `0.000312875` seconds/run
- bespoke: about `0.000259125` seconds/run
- ratio: about `1.21x`
- allocation stayed about `1_300` bytes/run

The full diagnostic benefits because its state-buffer section is represented as
three one-child `Routine`s. The compatibility benchmark is mostly unaffected.

## Rejected Experiment: Positional View Construction

Temporarily changed routed `_step!` methods to call the positional
`view(context, algo, (;), shares, routes)` constructor instead of the keyword
form `view(context, algo; sharedcontexts = ..., sharedvars = ...)`.

This was slower:

- compatibility ratio regressed to about `1.85x`
- full diagnostic ratio regressed to about `1.62x`

The change was reverted.

## Optimization 5: Avoid `Nothing`-Widened Context View

Changed `src/Identifiable/Step.jl`.

`_step!(::IdentifiableAlgo, ...)` initialized `contextview = nothing` before
assigning the actual view in a branch. Rewrote this to assign the branch result
directly:

```julia
contextview = if !isempty(wiring)
    ...
else
    ...
end
```

This materially improved the manual routed-buffer target, which is dominated by
identified process-algorithm view/merge calls.

With larger runs to reduce timing noise:

`ROUTE_BUFFER_COMPAT_STEPS=10000 ROUTE_BUFFER_COMPAT_RUNS=100`:

- routed: about `0.001196538` seconds/run
- bespoke: about `0.001048895` seconds/run
- ratio: about `1.14x`
- allocation stayed below bespoke allocation

`ROUTE_TRANSPARENCY_STEPS=10000 ROUTE_TRANSPARENCY_RUNS=100`:

- routed: about `0.001567304` seconds/run
- bespoke: about `0.001330269` seconds/run
- ratio: about `1.18x`
- allocation stayed below bespoke allocation

## Optimization 6: Static Empty/Routed Step Methods And Stored Child Wiring

Changed:

- `src/Identifiable/Step.jl`
- `src/Widgets/FuncWrapper.jl`
- `src/LoopAlgorithms/Step.jl`

Split identified-algorithm and `FuncWrapper` stepping into explicit methods for
empty `Wiring{Tuple{}, Tuple{}}` and non-empty `Wiring`. This removes the
runtime `isempty(wiring)` branch from the hot path.

Also changed generated composite/routine stepping to read child wiring from the
stored `PlanWiring` value with `getfield(child_wiring(wiring), i)`, instead of
reconstructing each child wiring from its type every step.

Repeated benchmark invocations are noisy immediately after recompilation, but
the stable second invocation at `10_000` steps shows:

- `route_buffer_compat_benchmark`: about `1.14x` routed/bespoke, with routed
  allocation lower than bespoke
- `route_transparency_diagnostic`: about `1.1x` to `1.2x` routed/bespoke, with
  routed allocation lower than bespoke

## Rejected Experiments

Two additional hot-path experiments were tried and reverted:

- Direct `stablemerge` generation through `merge_into_subcontext` calls. This
  was slower than the existing intermediate merge tuple path.
- A repeat-1 `Routine` child fast path. This did not materially improve the
  full diagnostic and added routine-specific complexity.

## Generated Whole-Loop Pass

Updated generated loop stepping to match the current runtime semantics:

- generated loop entry points now take runtime inputs and a `Resuming` marker,
  like the non-generated loop entry points
- generated step expressions receive the resolved wiring value and pass it to
  `_step!(..., wiring, process, lifetime, stability)`
- generated composite/routine expressions pass each child its stored child
  wiring with `getfield(child_wiring(wiring), i)`
- the precompile workload now calls the generated loop with the full current
  signature

With `sys_looptype` temporarily changed to `Generated()` and the standard
targets run at `10_000` steps / `100` runs:

- `route_buffer_compat_benchmark`: `0.001132825` routed seconds/run vs
  `0.001038351` bespoke seconds/run, ratio `1.091x`, routed bytes/run
  `1025.6`
- `route_transparency_diagnostic`: `0.001548809` routed seconds/run vs
  `0.001318731` bespoke seconds/run, ratio `1.174x`, routed bytes/run
  `1297.6`

This confirms the previous suspicion: a whole generated loop is not a major
improvement for the full routed diagnostic. It may shave a little time from the
manual buffer-compat path, but the transparency target remains governed by the
same view/writeback/state-wrapper work as the non-generated loop.

After restoring `sys_looptype = NonGenerated()` and taking a clean post-compile
sample at the same size:

- `route_buffer_compat_benchmark`: ratio `1.113x`, routed bytes/run `1025.6`
- `route_transparency_diagnostic`: ratio `1.195x`, routed bytes/run `1297.6`

The generated whole-loop pass is therefore roughly neutral for the full target
and only marginally faster on the smaller manual routed-buffer target.

## Non-Generated Unrollreplace Step Recheck

Restored the older non-generated `unrollreplace_withargs` implementations for
`CompositeAlgorithm` and `Routine` stepping in `src/LoopAlgorithms/Step.jl`.
The generated child-step implementations were left commented in the same file
so they can be toggled back without reconstructing the experiment.

Clean second samples at `10_000` steps / `100` runs with the unrolled
non-generated child-step path:

- `route_buffer_compat_benchmark`: `0.001432977` routed seconds/run vs
  `0.001040072` bespoke seconds/run, ratio `1.378x`, routed bytes/run
  `1025.6`
- `route_transparency_diagnostic`: `0.001883297` routed seconds/run vs
  `0.001303469` bespoke seconds/run, ratio `1.445x`, routed bytes/run
  `1297.6`

The unrolled `unrollreplace_withargs` path is slower than the generated
child-step path for these route-heavy targets. It keeps allocations low, so the
regression is CPU overhead rather than the old runtime-global allocation issue.

The `@merge`/`@context` buffer bug remains fixed under this path. The breakdown
diagnostic at the same size reported:

- `merge_state_buffer_only`: `0.00033528541` seconds/run, `80.16` bytes/run
- `context_state_buffer_no_merge`: `0.00038201458` seconds/run, `288.16`
  bytes/run

Those values are allocation-light and no longer show the previous MB-scale
runtime growth.

## Hot-Path Cleanup

Polished the active generated child-step path after the unrollreplace recheck:

- kept the generated `CompositeAlgorithm` and `Routine` step implementations
  active, with the unrollreplace alternatives commented after the active code
- made generated builders bind `algo_count` once, pre-size their expression
  vectors, and compute the "needs composite counter" flag at generation time
- kept stored child wiring reuse in generated child calls
- changed empty-wiring `_step!` methods to use explicit `::W where W<:...`
  selectors, matching the package's specialization style
- added a `FuncWrapper` `nothing` return fast path for pure side-effecting
  wrappers

Clean samples after this cleanup:

- `route_buffer_compat_benchmark`: ratio `1.160x`, routed bytes/run `1025.6`
- `route_transparency_diagnostic`: ratio `1.177x`, routed bytes/run `1297.6`

## Generated Step Wiring Simplification

Simplified the active generated `CompositeAlgorithm` and `Routine` child-step
paths so each generated child call computes its wiring value at generation time
from the child wiring tuple type:

- `child_wiring_type = W.parameters[2]`
- child `i` receives `fieldtype(child_wiring_type, i)()` interpolated into the
  generated body

This uses the existing recursive `Wiring{...}()` / `PlanWiring{...}()`
constructors instead of duplicating wiring reconstruction logic inside the
generated step builders. The emitted hot loop still receives a concrete wiring
literal per child and does not inspect runtime `PlanWiring` fields.

Also collapsed the composite interval lookup to `CA.parameters[2]`, since
normal construction/edit paths store composite intervals as a tuple type
parameter.

Longer post-change samples at `10_000` steps / `500` runs:

- `route_buffer_compat_benchmark`: `0.001227360` routed seconds/run vs
  `0.001049507` bespoke seconds/run, ratio `1.169x`, routed bytes/run
  `1024.3`
- `route_transparency_diagnostic`: `0.001557422` routed seconds/run vs
  `0.001334400` bespoke seconds/run, ratio `1.167x`, routed bytes/run
  `1296.3`
