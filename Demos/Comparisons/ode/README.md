# ODE solvers: can StatefulAlgorithms host or re-implement what SciML is good at?

SciML's strength is its solver library: adaptive error control, high-order methods, implicit solvers
for stiff problems. This asks whether that fits on the StatefulAlgorithms backend, two ways:

- **re-implement** (`R`): Dormand-Prince 5(4) with step-size control, one attempt per `step!`,
  written as a `@StepAlgorithm` (`variants.jl`), run under `InlineProcess` with `Until(t >= tend)`;
- **host** (`W`): SciML's own integrator kept in a `@managed` field of a `@StepAlgorithm`, advanced with
  `step!(integ)` once per call.

Against SciML itself (`S`) and a hand-written loop (`H`) around the same Dormand-Prince core
(`dp5.jl`; `H` and `R` share `dp5_attempt!`, so the arithmetic is identical). The I-controller is
configured to match SciML's, and the step counts then agree exactly (S1 vs H/R below).

```bash
julia --project=Demos/Comparisons/ode -e 'using Pkg; Pkg.instantiate()'     # first time only
julia --project=Demos/Comparisons/ode Demos/Comparisons/ode/run.jl [lorenz|brusselator|robertson|all]
```

## Head-to-head: StatefulAlgorithms vs SciML

Same method (Dormand-Prince 5(4)) in both, same step-size controller, same tolerances; the two take the
same number of steps and reach the same error, so only the machinery around the method differs.
"SciML time / ours" is SciML's time per solve divided by ours, so a value above 1 means SciML is slower
and a value below 1 means SciML is faster. Ours is the re-implementation as a `@StepAlgorithm`.

| problem | tolerance | StatefulAlgorithms, ms per solve | SciML DP5, ms per solve | SciML time / ours | attempts | relative error |
|---|---|---|---|---|---|---|
| Lorenz, 3 variables | 1e-6 | 0.022 | 0.028 | 1.27 | 161 (both) | 9.4e-6 (SciML: 9.3e-6) |
| Lorenz, 3 variables | 1e-9 | 0.069 | 0.083 | 1.20 | 621 (both) | 9.3e-9 (both) |
| Brusselator PDE, 2048 variables | 1e-6 | 0.293 | 0.283 | 0.97 | 22 (SciML: 21) | 4.6e-7 (SciML: 4.1e-7) |

Hosting SciML inside a StatefulAlgorithms step instead of calling it directly:

| problem | hosted in a step, ms per solve | SciML called directly, ms per solve | hosted time / direct time |
|---|---|---|---|
| Lorenz 1e-6, DP5 | 0.036 | 0.028 | 1.29 |
| Lorenz 1e-9, DP5 | 0.098 | 0.083 | 1.18 |
| Brusselator 1e-6, DP5 | 0.299 | 0.283 | 1.06 |
| Robertson 1e-6, Rodas5P (separate run, two variants only) | 0.033 | 0.025 | 1.32 |

## All variants

"time / H" is the variant's time divided by H's time (H = the hand-written loop around the same core).
Julia 1.13.1, load average 3-6, minimum over 7 interleaved rounds. The harness prints the same columns.

| variant | Lorenz 1e-6, ms | time / H | Lorenz 1e-9, ms | time / H | Brusselator 1e-6, ms | time / H |
|---|---|---|---|---|---|---|
| H hand-written loop | 0.015 | 1.00 | 0.060 | 1.00 | 0.297 | 1.00 |
| H0 hand-written, no function barrier | 0.036 | 2.32 | 0.133 | 2.24 | 0.291 | 0.98 |
| R StatefulAlgorithms `@StepAlgorithm` | 0.022 | 1.41 | 0.069 | 1.15 | 0.293 | 0.99 |
| S1 SciML DP5 | 0.028 | 1.81 | 0.083 | 1.39 | 0.283 | 0.95 |
| W SciML DP5 hosted in a step | 0.036 | 2.34 | 0.098 | 1.64 | 0.299 | 1.00 |

## What the numbers say

- **Re-implementing a solver on the backend works.** The same method, controller and tolerances take the
  same steps and reach the same error as SciML's. Against SciML's DP5 the re-implementation is 1.27 and 1.20
  times faster on the 3-variable problem (SciML time / ours) and equal on the 2048-variable PDE (0.97).
  Against the hand-written loop around the same core it costs about 6 µs per run plus a few ns per attempt.
- **Hosting a solver works too.** SciML's integrator kept in a managed field and stepped from a plan takes
  1.06 to 1.29 times as long as calling SciML directly (hosted time / direct time), the largest on the
  smallest problem. That includes the stiff Rodas5P (1.32 in a run with only the two Rodas5P variants; the absolute gap is about 8 µs in every run).
- **The function barrier is visible.** H0 builds its buffers as a NamedTuple whose shape is only known at
  run time and uses them in the same function: 2.2-2.3x slower than H on the small problem. H (and R, whose
  buffers are built in `init`) get the barrier for free. A user can add the barrier by hand (that is what H
  does), so this is "automatic", not "unique".

## Limits of this comparison

Only the non-stiff re-implementation and the hosted-SciML paths (DP5 and Rodas5P) were run; no stiff solver was re-implemented. Not tested: events and
callbacks, dense output and `saveat`. Schedules in StatefulAlgorithms are in iteration counts
(`(1, 10)` intervals, `@every n`), while continuous-time solvers want time-based output; a logger
that fires when `t` crosses a grid would have to be written as an algorithm. That is a mismatch in
the model, not measured here.
