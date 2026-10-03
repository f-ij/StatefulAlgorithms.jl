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

**Only the loop is timed.** Every variant first builds its integrator, process or buffers (untimed);
the timed part is `run(process)`, `solve!(integrator)`, a `step!` loop, or the hand-written loop, on
that prebuilt state. Variants are interleaved, and each value is the minimum over 7 rounds of the mean
loop time of freshly set-up runs. Julia 1.13.1, load average 3-6. Relative error is against a Vern9
solution at 1e-14; the attempts (accepted + rejected steps) and errors of the variants below agree
(Lorenz 1e-6: 161 attempts and 9e-6 everywhere; 1e-9: 621; 1e-12: 2461).

## Re-implemented: StatefulAlgorithms vs SciML, same method (Dormand-Prince 5(4))

"SciML time / ours" is SciML's loop time divided by ours: above 1 means SciML is slower, below 1 faster.
SciML's loop is `solve!()` on a built integrator, its fastest driver. "default" is `@StepAlgorithm`
as written; "@inline" is the same algorithm with the `@inline` opt-in.

| problem | tolerance | ours, default, ms | ours, @inline, ms | SciML solve!(), ms | SciML time / ours, default | SciML time / ours, @inline |
|---|---|---|---|---|---|---|
| Lorenz, 3 variables | 1e-6 | 0.0172 | 0.0166 | 0.0205 | 1.19 | 1.23 |
| Lorenz, 3 variables | 1e-9 | 0.0649 | 0.0630 | 0.0780 | 1.20 | 1.24 |
| Lorenz, 3 variables | 1e-12 | 0.2562 | 0.2491 | 0.3067 | 1.20 | 1.23 |
| Brusselator PDE, 2048 variables | 1e-6 | 0.2717 | 0.2850 | 0.2583 | 0.95 | 0.91 |

On the PDE the variants are within the run-to-run noise of about 5%.

## Hosted: SciML's integrator inside a StatefulAlgorithms step vs SciML called directly

Two baselines: `solve!()`, SciML's own internal loop, and a plain `step!` loop, which is what hosting
does (one `step!` per call). "hosted / X" is the hosted loop time divided by X's loop time.

| problem | tolerance | hosted, ms | SciML solve!(), ms | SciML step! loop, ms | hosted / solve!() | hosted / step! loop |
|---|---|---|---|---|---|---|
| Lorenz, DP5 | 1e-6 | 0.0231 | 0.0205 | 0.0232 | 1.13 | 1.00 |
| Lorenz, DP5 | 1e-9 | 0.0885 | 0.0780 | 0.0897 | 1.13 | 0.99 |
| Lorenz, DP5 | 1e-12 | 0.3493 | 0.3067 | 0.3559 | 1.14 | 0.98 |
| Brusselator, DP5 | 1e-6 | 0.2532 | 0.2583 | 0.2544 | 0.98 | 1.00 |
| Robertson (stiff), Rodas5P | 1e-6 | 0.0161 | 0.0156 | 0.0168 | 1.03 | 0.96 |
| Robertson (stiff), Rodas5P | 1e-10 | 0.0742 | 0.0748 | 0.0762 | 0.99 | 0.97 |

Hosting adds nothing measurable over the same `step!` loop. The 13% against `solve!()` on the small
problem is SciML's own cost of stepping one call at a time versus its internal loop, not the framework.

## Against the hand-written loop (Lorenz 1e-12, 2461 attempts; time / H is relative to H)

| variant | loop, ms | time / H |
|---|---|---|
| H hand-written loop around the same core | 0.2468 | 1.00 |
| R2 `@StepAlgorithm`, `@inline` | 0.2491 | 1.01 |
| R `@StepAlgorithm`, default | 0.2562 | 1.04 |
| S1 SciML DP5, `solve!()` | 0.3067 | 1.24 |
| W SciML DP5 hosted in a step | 0.3493 | 1.42 |
| S5 SciML DP5, `step!` loop | 0.3559 | 1.44 |
| H0 hand-written, buffers in an untyped field | 0.6475 | 2.62 |

The default step is 4 to 5% over hand-written on this small problem, about 4 ns per attempt: the
unforced call to the algorithm body (see `../ising/README.md`). `@inline` removes it. On the PDE nothing
differs.

H0 keeps the same buffers in an untyped field so the compiler cannot infer their type, as with state
read from a mutable abstractly typed struct. It is 2.6 times slower on the small problem and no slower on the
PDE. R builds its buffers in `init`, so its loop sees concrete types. A hand-written loop can get the
same by passing the buffers to a function (H does), so this is automatic, not unique.

## Limits

Only the non-stiff re-implementation and the hosted paths (DP5 and Rodas5P) were run; no stiff solver
was re-implemented. Events, callbacks, dense output and `saveat` were not tested. Schedules in
StatefulAlgorithms count iterations (`(1, 10)` intervals, `@every n`), while continuous-time solvers
want time-based output; a logger that fires when `t` crosses a grid would be written as an algorithm.
Building a process takes a few microseconds once; it is excluded here.
