# A driven ODE with an external force: StatefulAlgorithms vs SciML

A chain of 64 nonlinear oscillators (128 variables: double-well on-site potential, harmonic coupling, damping 1.0) is
driven by an external force, integrated to t = 4000 with a step-size-controlled Dormand-Prince 5(4) at tolerance 1e-6, and
checkpointed every 20 accepted steps. The question: when the force, the checkpoints and later "modifiers" are separate
components composed around the integrator, what does that cost at run time, how much code does the user write, and how much
has to be decided in advance? Compared: StatefulAlgorithms, SciML (callbacks on a mutable parameter), and a hand-written loop
as the reference for correctness and cost.

## Findings

1. **A force as its own component costs nothing at run time.** With the force a separate `@StepAlgorithm` that writes `F`
   into the context and the integrator reading it, the package runs at 0.96 to 0.98 times the hand-written loop, with
   bit-identical results. SciML with callbacks takes 20 to 27% longer than the package on the same runs.
2. **Modifiers on internal variables also cost nothing.** Adding a damping ramp, a tolerance schedule and state kicks
   (components that read and write the integrator's internals by name) leaves the package at 0.65 microseconds per attempt
   in every combination; SciML's per attempt grows from 0.78 to 0.87 microseconds as callbacks are added (1.20 to 1.34 times
   the package's loop time).
3. **Front-end code.** The experiment is a 9-line DSL block (14 lines with setup and run) when the components exist,
   against 30 lines of callbacks and setup in SciML; when the user also writes the four components it is 38 lines against
   30. The package's components are reusable because they refer to variables by name; a SciML callback is written
   against the problem's structure (`i.p.par`, `i.opts.reltol`, `u_modified!`).
4. **Nothing has to be decided in advance in the package.** An integrator can return all its state and parameters as
   variables from the start; twelve extra unread variables cost 0.4 to 1.1% (noise level). SciML needs everything a later
   experiment may change to be a field of a mutable parameter struct, decided up front. A mutable struct costs nothing
   when the right-hand side reads it once at the top, and 2 to 6% when it reads it inside the loop.
5. **Limits are listed at the end**: the integrator and checkpointer counted as library, a small kernel, SciML's slightly
   different step counts, noise of about 2%.

## How to run

```bash
julia --project=Demos/Comparisons/driven -e 'using Pkg; Pkg.instantiate()'     # first time only
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run.jl                # one force at a time
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run_modifiers.jl      # modifiers on internals
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/check_frontend.jl     # runs the counted front-end code
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/unread_variables.jl   # cost of exposing everything
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/mutable_cost.jl       # cost of a mutable parameter struct
```

Files: `scenario.jl` (system, force shapes, constants), `hand.jl` (hand-written reference), `framework.jl` (the package:
drives, integrator, checkpointer), `sciml.jl` (SciML with callbacks), `modifiers.jl` (modifiers for all three),
`frontend.jl` (the user-facing code that is counted).

Only the loop is timed: integrators, processes and buffers are built first. Implementations are interleaved; each value is
the minimum over 7 to 9 rounds of the mean of 5 freshly set-up runs. Julia 1.13.1, load average 3-6; run-to-run noise is
about 2%.

## The work every implementation does

One force shape per run. The force is computed once per step from the current time (and, for feedback, the current state) and
held for that step. Each step is: the Dormand-Prince attempt with step-size control, then the force for the next step, then a
checkpoint every 20 accepted steps. When the force or anything inside the integrator changes, the first stage of the next
step is recomputed. The hand-written loop and the package use the same Dormand-Prince core (`../ode/dp5.jl`) and give
bit-identical results.

- **Package:** the force is a `@StepAlgorithm` (`SineDrive`, `SquareDrive`, `FeedbackDrive`) that reads the routed time (and
  state) and writes `F`; the integrator `ChainDP5` reads `F`; a `Checkpointer` takes the snapshots. `F` is a value in the
  context, not a mutable field, so the compiler removes the accesses. Several drives go in a nested `Routine` with a small
  adder algorithm (last row below).
- **SciML:** `F` lives in a mutable parameter that a `DiscreteCallback` writes after each accepted step (with `u_modified!` when
  it changed), and a second callback takes the checkpoints.

## One force at a time

"SciML time / ours" is SciML's loop time divided by the loop time of StatefulAlgorithms, so 1.22 means SciML takes 22%
longer. Per attempt is given too because SciML's controller takes slightly different numbers of steps.

| force | ours, loop ms | SciML, loop ms | SciML time / ours | ours, microseconds per attempt | SciML, microseconds per attempt | SciML time per attempt / ours |
|---|---|---|---|---|---|---|
| sine | 11.94 | 14.54 | 1.22 | 0.657 | 0.801 | 1.22 |
| square pulse train | 13.04 | 16.50 | 1.27 | 0.623 | 0.782 | 1.26 |
| feedback on mean x (two-way) | 2.37 | 2.84 | 1.20 | 0.647 | 0.795 | 1.23 |
| sine + feedback together (nested Routine) | 11.09 | 13.45 | 1.21 | 0.659 | 0.800 | 1.21 |

Relative to the hand-written loop ("time / H" is the loop time divided by the hand-written loop's, H = 1.00):

| force | H, loop ms | ours, loop ms | ours, time / H | SciML, loop ms | SciML, time / H |
|---|---|---|---|---|---|
| sine | 12.40 | 11.94 | 0.96 | 14.54 | 1.17 |
| square pulse train | 13.42 | 13.04 | 0.97 | 16.50 | 1.23 |
| feedback on mean x | 2.47 | 2.37 | 0.96 | 2.84 | 1.15 |
| sine + feedback together | 11.34 | 11.09 | 0.98 | 13.45 | 1.19 |

Attempts (accepted + rejected) and checkpoints: ours and H are identical (sine 15283 + 2874, 764 checkpoints; square
19125 + 1802, 956; feedback 2997 + 660, 149; both 14349 + 2466, 717). SciML: sine 15283 + 2873 (764), square 19257 + 1832
(962), feedback 2986 + 591 (149), both 14348 + 2462 (717).

Correctness: the final state of the package is bit-identical to the hand-written loop in every case. SciML's relative
difference to it: sine 5.5e-4, feedback 3.8e-6, both 7.9e-5. For the square pulse train the force is discontinuous and sampled
once per step, so the state depends on the step sequence and two different controllers' `u(T)` are not comparable (relative
difference 1.1); only its timing is meaningful.

## Modifiers on internal variables

The integrator (`ChainDP5M`) exposes its internals as variables: the parameters `par`, the tolerance `rtol`, the state
`u`, and a `stale` flag that says the first stage must be recomputed. Modifiers are small algorithms that read and write them
by name: `DampingRamp` (damping 1.0 to 0.8 over the run), `ToleranceSchedule` (rtol rising to 10 times), `StateKick` (an
impulse to oscillator 1 every 500 accepted steps). No new struct is defined for an experiment; which modifiers a run has is
decided when the plan is built. SciML does the same with callbacks that write into the mutable parameter (`i.p.par = ...`), the
options (`i.opts.reltol = ...`) and the state (`i.u`), each followed by `u_modified!`.

| modifiers | ours, loop ms | SciML, loop ms | SciML time / ours | ours, microseconds per attempt | SciML, microseconds per attempt |
|---|---|---|---|---|---|
| none | 11.86 | 14.21 | 1.20 | 0.653 | 0.783 |
| damping ramp | 12.29 | 15.53 | 1.26 | 0.653 | 0.825 |
| damping ramp + tolerance schedule | 11.10 | 14.56 | 1.31 | 0.654 | 0.858 |
| kick + damping ramp + tolerance schedule | 11.09 | 14.82 | 1.34 | 0.655 | 0.874 |

The package's final state is bit-identical to the hand-written loop in every row; SciML's differs from it by 5.5e-4, 2.0e-3,
1.5e-3 and 5.9e-3. An earlier version let the damping fall to 0.5, which is chaotic: the final states of different step
controllers then differ by order 1, which is trajectory divergence and says nothing about correctness, so the ramp stops at 0.8.

## Front end: what the user writes

Counted for the full experiment (sine drive, checkpoints, the three modifiers), with the library parts hidden: for the package
the integrator and the checkpointer, for SciML the solver. The right-hand side and the force functions are shared and not
counted. `frontend.jl` holds exactly this code and `check_frontend.jl` runs it (package bit-identical to the hand-written
loop; SciML within 5.9e-3 of it).

```julia
integ = ChainDP5M()
experiment = @CompositeAlgorithm begin
    @alias integ = integ
    StateKick(u = integ.u, nacc = integ.nacc, stale = integ.stale)
    DampingRamp(t = integ.t, par = integ.par, stale = integ.stale)
    ToleranceSchedule(t = integ.t, rtol = integ.rtol)
    F = SineDrive(t = integ.t)
    integ(F = F)
    Checkpointer(u = integ.u, t = integ.t, dt = integ.dt, nacc = integ.nacc)
end
la = init(resolve(experiment), Init(integ; u0 = U0, par = PARAMS, rtol = RTOL))
run(la; lifetime = Until(t -> t >= TEND, Var(integ, :t)))
```

| what the user writes | StatefulAlgorithms, lines | SciML, lines |
|---|---|---|
| the experiment: composition, setup and run, with the drive, checkpoints and modifiers taken as ready-made components | 14 (the 9-line block, 3 lines of setup and run, 2 of function wrapper) | 30 (callbacks, setup and solve; there are no ready-made components) |
| plus defining the four components: `SineDrive` 4, `DampingRamp` 8, `ToleranceSchedule` 4, `StateKick` 8 | 14 + 24 = 38 | 30 (unchanged: the logic is in the callbacks) |

A naive count of the whole demo (61 lines of package code against 22 for SciML in the first version) mixes things: the package
count includes writing the integrator (17 lines, plus an 87-line shared core) that SciML supplies as a library. With the
integrator hidden and the composition counted as the user writes it, the numbers are the ones above. The package is shorter when
the components exist and slightly longer when the user writes them all; the difference is reuse. A component reads and writes
variables by name (`par`, `stale`, `t`), so it works with any integrator that exposes those names; a SciML callback carries the
structure of the problem with it. SciML callbacks can be packaged as constructor functions, but they keep those field paths.

## What has to be decided in advance

**SciML.** Anything a later experiment may change has to live in the parameter struct, which then has to be mutable (or in the
integrator's options). In this demo the SciML first experiment already had `mutable struct ChainPm; par; F; end` (the
callback-based force needs `F` writable and `par` sits in the same struct), so the three modifiers needed only 11 more callback
lines (kick 2, ramp 8, tolerance 1) and no struct change; this flatters SciML. An experiment that kept the sine force inside the
right-hand side with an immutable `p` would have had to turn it into a mutable struct holding every field that might later change.

**StatefulAlgorithms.** The first integrator (`ChainDP5`) happened to have the parameters and the tolerance as constants, so
adding the modifiers meant rewriting it as `ChainDP5M` with `par`, `rtol` and `stale` as managed variables (about 6 changed
lines). That was a choice, not a requirement: an integrator can return all its state and parameters as variables from the
start, and variables that nothing reads cost nothing at run time. `unread_variables.jl` checks this: the same integrator with
twelve extra variables of mixed types (scalars, arrays, a NamedTuple) that nothing reads runs at 1.011, 1.004 and 1.006 times
the loop time of the minimal one (3 to 7 nanoseconds per attempt, the noise level of these runs) with identical results.
Compile time was not measured.

**What a mutable parameter struct costs** (`mutable_cost.jl`). The same chain, the sine force computed from `t` inside the
right-hand side so nothing writes into `p`, with the parameters in an immutable versus a mutable struct. The only difference
is what the type lets the compiler do. "mutable / immutable" is the loop time with a mutable `p` divided by the loop time with
an immutable `p`, same implementation and same right-hand side; the range is over two runs. Immutable p, microseconds per
attempt: SciML 0.625 to 0.639, hand-written 0.643 to 0.658.

| right-hand side reads p | SciML, mutable / immutable | hand-written loop, mutable / immutable |
|---|---|---|
| once, at the top | 1.000 to 1.004 | 0.999 to 1.024 |
| inside the loop (`p.par.a * x` and so on) | 1.037 to 1.056 | 1.017 to 1.029 |

A mutable struct is free when its fields are read once before the loop. Read inside the loop, the compiler cannot keep the
values in registers (a store to `du` may alias a field of `p`) and reloads them every iteration: 2 to 6% on this kernel. Results are
identical in both cases. For comparison, each further callback in the modifiers table adds 0.02 to 0.04 microseconds per attempt
(2.5 to 5% of 0.78).

## Limits

- The integrator and the checkpointer are code written for this demo; counting them as library assumes they ship with the package.
- This is a small kernel (about 0.65 microseconds per attempt), so per-step costs show; a heavier right-hand side shrinks every
  ratio towards 1 (see `../ode`).
- The force is sampled once per step in every implementation. In SciML a force that depends only on time could instead sit inside
  the right-hand side, continuous in time; that is a different model and was not compared (the mutable-cost experiment above does
  that, but only to isolate the struct cost).
- SciML takes slightly different numbers of steps than the package (its controller differs in details), hence the per-attempt columns.
- Each run uses one fixed composition (a plan with its drives in a nested `Routine` when there are several). Restoring a checkpoint
  into a changed setup was not tested. Noise is about 2%; ratios within a few percent of 1 are not distinguishable from it.
