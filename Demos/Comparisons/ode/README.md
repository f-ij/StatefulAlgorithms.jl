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

Time per solve (min of 7 interleaved rounds), attempts = accepted + rejected steps, relative error
against a Vern9 solution at 1e-14. Julia 1.13.1, load average 3-6.

| problem, tolerance | S1 SciML DP5 | S2 SciML Tsit5 | H hand-written | R `@StepAlgorithm` | W hosted SciML DP5 | H0 no barrier |
|---|---|---|---|---|---|---|
| Lorenz (3 vars), 1e-6 | 0.028 ms | 0.025 | 0.015 | 0.022 | 0.036 | 0.036 |
| Lorenz, 1e-9 | 0.083 ms | 0.073 | 0.060 | 0.069 | 0.098 | 0.133 |
| Brusselator PDE (2048 vars), 1e-6 | 0.283 ms | 0.287 | 0.297 | 0.293 | 0.299 | 0.291 |

Attempts and errors: S1, H, R and W agree to within one attempt (Lorenz 1e-6: 161 attempts,
rel. err 9e-6; 1e-9: 621, 9e-9).

Stiff Robertson, t in [0, 100], tol 1e-6:

| | time | attempts | rel. error |
|---|---|---|---|
| S3 SciML Rodas5P (implicit) | 0.041 ms | 27 | 2.5e-6 |
| W2 Rodas5P hosted in a step | 0.049 ms | 27 | 2.5e-6 |
| H hand-written explicit DP5 | 15.9 ms | 146k | 2.7e-3 |
| R explicit DP5 as `@StepAlgorithm` | 16.7 ms | 146k | 2.7e-3 |

## What the numbers say

- **Re-implementing works and costs little.** R tracks the hand-written loop: about 6 µs fixed
  per run plus a few ns per attempt, so it is 1.15-1.4x on the 3-variable problem (where one attempt is
  ~100 ns) and indistinguishable (0.99x) when the right-hand side does real work (the PDE).
- **Hosting works.** Keeping SciML's integrator in a managed field and stepping it from a plan costs about
  8 µs fixed on top of calling SciML directly, and nothing measurable on the PDE. Anything composed around
  it (routes, loggers, protocols, interactive variables) comes for free.
- **What the backend does not provide is the solver library.** On the stiff problem the explicit method
  is ~400x slower and 1000x less accurate; the fix is an implicit solver, which here means hosting
  Rodas5P (or writing one with managed LU buffers), not a different backend design.
- **The function barrier is visible.** H0 builds its buffers as a NamedTuple whose shape is only known at
  run time and uses them in the same function: 2.2-2.3x slower on the small problem. H (and R, whose buffers
  are built in `init`) get the barrier for free. A user can add the barrier by hand (that is what H does), so
  this is "automatic", not "unique".

## Limits of this comparison

Only non-stiff explicit re-implementation and hosted-SciML paths were run. Not tested: events and
callbacks, dense output and `saveat`. Schedules in StatefulAlgorithms are in iteration counts
(`(1, 10)` intervals, `@every n`), while continuous-time solvers want time-based output; a logger
that fires when `t` crosses a grid would have to be written as an algorithm. That is a mismatch in
the model, not measured here.
