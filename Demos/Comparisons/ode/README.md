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
| Lorenz, 3 variables | 1e-9 | 0.068 | 0.081 | 1.19 | 621 (both) | 9.3e-9 (both) |
| Brusselator PDE, 2048 variables | 1e-6 | 0.284 | 0.269 | 0.95 | 22 (SciML: 21) | 4.6e-7 (SciML: 4.1e-7) |

Hosting SciML inside a StatefulAlgorithms step. The baseline is SciML's own `init` + `step!` loop driven
by plain Julia (inside a function that receives the integrator, so the loop is type-stable). It is not
`solve()`, which is a different and faster driver in SciML itself (0.028 vs 0.030 ms on Lorenz 1e-6), so
comparing hosting against `solve()` would charge the framework for SciML's own driver.

| problem, solver | hosted in a step, ms per solve | SciML init + step! loop, ms per solve | hosted minus loop, microseconds | hosted time / loop time |
|---|---|---|---|---|
| Lorenz 1e-6, DP5 | 0.036 | 0.030 | 6 | 1.20 |
| Lorenz 1e-9, DP5 | 0.097 | 0.093 | 4 | 1.04 |
| Brusselator 1e-6, DP5 | 0.290 | 0.278 | 12 | 1.04 |
| Robertson 1e-6, Rodas5P (stiff) | 0.031 | 0.023 | 8 | 1.35 |

The difference is a fixed cost per run, not a cost per step (`overhead.jl`, `overhead2.jl`, Lorenz,
hosted minus the plain loop):

| tolerance | attempts | hosted minus SciML loop, microseconds | per attempt, ns |
|---|---|---|---|
| 1e-6 | 161 | 5.9 | 36.9 |
| 1e-9 | 621 | 5.5 | 8.8 |
| 1e-12 | 2461 | 8.3 | 3.4 |

A linear fit gives about 5.8 microseconds fixed plus 1 ns per attempt (another run gave -4.7 ns per attempt:
zero within noise). The fixed part is building the process: constructing a trivial `InlineProcess` takes
3.9 microseconds and running an already built one 0.02 microseconds. A benchmark that builds a new process for every
30 microsecond solve pays it every time; a process that runs for longer pays it once.

## All variants

"time / H" is the variant's time divided by H's time (H = the hand-written loop around the same core).
Julia 1.13.1, load average 3-6, minimum over 7 interleaved rounds. The harness prints the same columns.

| variant | Lorenz 1e-6, ms | time / H | Lorenz 1e-9, ms | time / H | Brusselator 1e-6, ms | time / H |
|---|---|---|---|---|---|---|
| H hand-written loop | 0.015 | 1.00 | 0.059 | 1.00 | 0.286 | 1.00 |
| H0 hand-written, no function barrier | 0.035 | 2.31 | 0.131 | 2.23 | 0.278 | 0.97 |
| R StatefulAlgorithms `@StepAlgorithm` | 0.022 | 1.45 | 0.068 | 1.15 | 0.284 | 0.99 |
| S1 SciML DP5, `solve()` | 0.028 | 1.82 | 0.081 | 1.39 | 0.269 | 0.94 |
| S5 SciML DP5, `init` + `step!` loop | 0.030 | 2.00 | 0.093 | 1.58 | 0.278 | 0.97 |
| W SciML DP5 hosted in a step | 0.036 | 2.37 | 0.097 | 1.65 | 0.290 | 1.01 |

## What the numbers say

- **Re-implementing a solver on the backend works.** The same method, controller and tolerances take the
  same steps and reach the same error as SciML's. Against SciML's DP5 the re-implementation is 1.27 and 1.20
  times faster on the 3-variable problem (SciML time / ours) and equal on the 2048-variable PDE (0.97).
  Against the hand-written loop around the same core it costs about 6 µs per run plus a few ns per attempt.
- **Hosting a solver is a thin wrapper.** SciML's integrator kept in a managed field and stepped from a plan
  costs about 1 ns per step (zero within noise) plus a fixed 4-8 microseconds per run, which is building the
  process. That includes the stiff Rodas5P (8 microseconds on 23).
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
