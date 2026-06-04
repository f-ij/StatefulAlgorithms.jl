# DSL Compile Diagnostics

This note records the large-DSL compile/startup optimization pass.

Active probes:

- `diagnostics/big_dsl_statement_probe.jl`
- `diagnostics/routine_entry_latency_probe.jl`

## What Was Slow

The reduced free-phase shaped routine was not doing expensive user work once it
entered the DSL body. Its region markers showed reset, projection, repeated
dynamics, and copy-out completing in microseconds after entry.

The remaining large cost was compilation around the loop-plan entry and
generated child stepping. A low-compile run confirmed this: with
`--compile=min --optimize=0`, the 20-statement big DSL probe completed its
build/resolve/run stages quickly, so the normal multi-second times are compiler
specialization/codegen cost rather than semantic runtime work.

## Optimizations

1. DSL macros now build final `Routine`/`CompositeAlgorithm` values through
   `_dsl_build_loopalgorithm` from vectors instead of expanding to one giant
   vararg constructor call.

2. `_plan_child_wiring` now uses a runtime child-wiring builder for large
   `children * options` products. This avoids generating an O(children *
   options) constructor body for large route-heavy DSL plans.

3. A large-plan step fallback was tested and then removed. It improved cold
   `runprocessinline!`, but it put a child-count threshold and runtime stepping
   path into `LoopAlgorithms/Step.jl`. That is the wrong layer for the current
   construction-time work, so the step path is back to the normal generated
   unrolled behavior.

4. Accessors.jl `@set` was removed from active context rebuild paths. The
   replacement is package-local and deliberately small: `replace_namedtuple_field`
   rebuilds one existing `NamedTuple` field, while `withdata`, `withruntime`, and
   `withsubcontexts` rebuild the immutable context wrappers. This mimics only
   the behavior StatefulAlgorithms needs from `@set`, without generic lens machinery.

5. Constructor-time async loop precompile was disabled for user-shaped
   `Process` values. The previous constructor scheduled `Base.precompile` on a
   background task, but immediate `run`/`runprocessinline!` calls then compiled
   the same large loop in the foreground. On multi-threaded Julia this made the
   first run contend with the background compile.

6. Root option collection now avoids materializing all plan wiring options just
   to discard them. Large DSLs can have many route/share `LocalPlanOption`
   values and zero root options; collecting directly from `LoopAlgorithm`
   wrappers avoids a large recursive tuple build in `resolve`.

## Current Measurements

On the 20-statement big DSL probe after this pass:

- `dsl_eval_seconds`: about `5.88s`
- `resolve_seconds`: about `4.33s`
- `process_construct_seconds`: about `0.59s`
- `cold_runprocessinline_seconds`: about `3.09s`
- warmed `runprocessinline!` median: about `12us`

Before the runtime child-step fallback, the same 20-statement shape had warmed
`runprocessinline!` around `18ms` and cold `runprocessinline!` around
`5.4s` to `6.6s`.

On the 30-statement big DSL probe after the first large-plan step fallback, the
code completed:

- `dsl_eval_seconds`: about `8.7s` to `9.5s`
- `resolve_seconds`: about `6.7s` to `7.0s`
- `process_construct_seconds`: about `0.73s` to `0.76s`
- `cold_runprocessinline_seconds`: about `6.0s` to `7.1s`
- warmed `runprocessinline!` median after warmups: about `21us`

Before this pass, the 30-statement probe did not reach `dsl_eval_seconds` after
about 90 seconds in the normal compiler mode.

After focusing specifically on construction, the probe now splits
`dsl_eval_seconds` into expression creation, macro expansion, and expanded-body
evaluation. The generated child-wiring builder was commented out and replaced
with the runtime child-wiring builder, because child wiring is construction-time
metadata and is not on the step hot path. A batch registry insertion path was
also added for large raw `FuncWrapper` tuples.

Current 30-statement construction numbers with the step fallback removed:

- `dsl_expr_seconds`: about `0.00009s`
- `dsl_macroexpand_seconds`: about `0.34s` to `0.43s`
- `dsl_expanded_eval_seconds`: about `1.9s`
- `dsl_eval_seconds`: about `2.3s`
- `resolve_seconds`: about `3.2s` to `4.1s`
- `process_construct_seconds`: about `0.72s` to `0.82s`

Cold `runprocessinline!` is again around `8.4s` to `9.6s` for the 30-statement
probe, because the large generated step method is compiled at first execution.
That is separate from DSL construction time.

After replacing Accessors with the package-local immutable rebuild helpers, the
30-statement probe measured:

- `dsl_expr_seconds`: `0.000096s`
- `dsl_macroexpand_seconds`: `0.363s`
- `dsl_expanded_eval_seconds`: `1.880s`
- `dsl_eval_seconds`: `2.270s`
- `resolve_seconds`: `4.069s`
- `process_construct_seconds`: `0.823s`
- `cold_runprocessinline_seconds`: `9.630s`

## 2026-05-31 Commit Comparison

The 30-statement probe was run against current code and the two preceding
commits:

```text
current before this pass:
  dsl_eval_seconds                2.066862250
  resolve_seconds                 3.067435834
  process_construct_seconds       0.666469084
  cold_runprocessinline_seconds   8.394210458

HEAD~1 (492a6de):
  dsl_eval_seconds                2.177242791
  resolve_seconds                 3.253790458
  process_construct_seconds       0.712256709
  cold_runprocessinline_seconds   8.773138291

HEAD~2 (3991889):
  dsl_eval_seconds                2.217516334
  resolve_seconds                 3.279817667
  process_construct_seconds       0.731220041
  cold_runprocessinline_seconds   8.587518250
```

So there is no compile-time regression across those commits; current was already
slightly better. The dominant cost remains first-entry compilation of the large
step path.

After this pass, a clean 30-statement run measured:

```text
dsl_eval_seconds                1.984218375
resolve_seconds                 2.952328917
process_construct_seconds       0.572973916
cold_runprocessinline_seconds   7.680886792
```

The same probe is noisy across fresh Julia processes, but the stable findings
are:

- root option collection dropped from roughly `0.32s` to about `0.004s` in the
  resolve breakdown;
- process construction dropped by about `0.1s`;
- cold first entry improved by about `0.7s` to `1.7s` depending on run, mostly
  by removing background compile contention;
- the 60-statement probe is still bad, with cold first entry around `25s`.

The small five-algorithm route-heavy benchmark remained on target after forcing
runtime child wiring: about `0.00153s` routed/process execution versus about
`0.00154s` for the plain loop, with zero routed bytes.

The precompile workload now also includes a package-owned 20-statement DSL
routine made entirely of plain function calls, state routes, keyword routes, and
one transform route. This is intended to precompile generic DSL construction
machinery that applies to any user DSL. It cannot precompile a user's exact
function/lambda types or exact context shape, so it improves but does not
eliminate construction latency. On this machine it increased StatefulAlgorithms package
precompile by roughly 5 seconds and moved the 30-statement diagnostic's
construction phases modestly lower, especially resolve and cold entry.

On the 60-statement big DSL probe, the current code completes with warmed
execution still sub-millisecond:

- `dsl_eval_seconds`: about `10.7s`
- `resolve_seconds`: about `14.7s`
- `process_construct_seconds`: about `1.77s`
- `cold_runprocessinline_seconds`: about `22.7s`
- warmed `runprocessinline!` median after warmup: about `125us`

The reduced free-phase shaped `routine_entry_latency_probe.jl` remains in the
same range as before for small plans, with warmed `runprocessinline!` around
`15us` to `17us`. That is expected because it stays below the large-plan
fallback threshold and keeps the fully specialized small-plan path.

The five-algorithm inline route-heavy benchmark also stays on the small-plan
path. With `20_000` steps and `5` runs it measured routed/process execution at
about `0.00155s` per run versus the plain loop at about `0.00161s`, with zero
bytes per routed run. The type-stability probe still reports inferred return
types for public `run`, direct loop, generated process-loop, and direct plan
entrypoints.

## Step Shape Experiments

Replacing the generated composite/routine `_step!` methods with the older
non-generated `unrollreplace_withargs` shape did not improve cold entry. The
30-statement probe moved to about `8.50s` cold run time, and the 60-statement
probe moved to about `26.47s`; both were worse than the generated baseline.

An inline recursive `unrollreplace_withargs_recursive` variant was also tested
as a possible way to give inference/source lowering smaller pieces while still
allowing inlining. It did not work out: the 30-statement probe reached process
construction, then stayed in the first `runprocessinline!` compile for several
minutes and was killed. That variant was reverted. If we revisit it, the zip
handling should avoid `map(first, zips)` / `map(Base.tail, zips)` and use an
explicit tuple recursion or generated zip extraction instead.

A package-local generated `NamedTuple` merge replacement for
`merge(getdata(subcontext), args)` was also tried. It preserved tests and warm
route-heavy runtime, but it did not improve cold compile time: the 30-statement
probe stayed around `8s` cold entry and the 60-statement probe worsened to about
`30s`. That experiment was reverted, which suggests the main issue is not
`Base.merge` itself but the repeated full-context aggregate replacement around
the merge.

## Remaining Cost

The remaining multi-second cost is now mostly `dsl_eval` and `resolve`, not the
steady-state step loop. The likely remaining sources are construction and
resolution of very large concrete route/context types, especially `FuncWrapper`
chains whose intermediate runtime variables all become distinct typed route and
context-view shapes.
