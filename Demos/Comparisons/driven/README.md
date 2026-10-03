# A driven ODE with an external force: StatefulAlgorithms vs SciML

A chain of 64 nonlinear oscillators (128 variables: double-well on-site potential, harmonic coupling, damping 1.0)
driven by an external force `F`, integrated to t = 4000 with a step-size-controlled Dormand-Prince 5(4)
(tolerance 1e-6), taking a checkpoint (a copy of `t`, the step size and the state) every 20 accepted steps.
One run uses one force at a time; the force is computed once per step from the current time (and, for
feedback, the current state) and held for that step. The same thing is done in every implementation: step, then
the force for the next step, then the checkpoint. When the force changes, the first stage of the next step is
recomputed with it.

```bash
julia --project=Demos/Comparisons/driven -e 'using Pkg; Pkg.instantiate()'     # first time only
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run.jl
```

Only the loop is timed: integrators, processes and buffers are built first (untimed). Variants are interleaved;
each value is the minimum over 7 rounds of the mean of 5 freshly set-up runs. Julia 1.13.1, load average 3-6.

## How the force is composed in each implementation

- **StatefulAlgorithms (`framework.jl`):** the force is its own `@StepAlgorithm` (`SineDrive`, `SquareDrive`,
  `FeedbackDrive`). It reads the time (and state) routed from the integrator and writes `F`; the integrator
  `ChainDP5` reads `F`. Changing the force shape means changing one algorithm in the plan; the integrator is
  untouched, and `F` is a value in the context, not a mutable field, so the compiler removes the accesses.
  Several drives go in a nested `Routine` (last case below) with a small algorithm that adds their forces.
- **SciML (`sciml.jl`):** `F` lives in a mutable parameter that a `DiscreteCallback` writes after every accepted
  step (with `u_modified!` when it changed, so the first stage is recomputed), and a second callback takes the checkpoints.
- **Hand-written (`hand.jl`):** one loop with the force a local variable; the baseline for correctness and cost.

## Head-to-head: StatefulAlgorithms vs SciML

"SciML time / ours" is SciML's loop time divided by the loop time of StatefulAlgorithms, so 1.22 means SciML
takes 22% longer. The microseconds-per-attempt ratio is given as well because the two take slightly different
numbers of attempts (SciML's controller differs in details).

| force | ours, loop ms | SciML, loop ms | SciML time / ours | ours, microseconds per attempt | SciML, microseconds per attempt | SciML time per attempt / ours |
|---|---|---|---|---|---|---|
| sine | 11.94 | 14.54 | 1.22 | 0.657 | 0.801 | 1.22 |
| square pulse train | 13.04 | 16.50 | 1.27 | 0.623 | 0.782 | 1.26 |
| feedback on mean x (two-way) | 2.37 | 2.84 | 1.20 | 0.647 | 0.795 | 1.23 |
| sine + feedback together (nested Routine) | 11.09 | 13.45 | 1.21 | 0.659 | 0.800 | 1.21 |

## All three, relative to the hand-written loop

"time / H" is the loop time divided by the hand-written loop's loop time (H = 1.00).

| force | H, loop ms | ours, loop ms | ours, time / H | SciML, loop ms | SciML, time / H |
|---|---|---|---|---|---|
| sine | 12.40 | 11.94 | 0.96 | 14.54 | 1.17 |
| square pulse train | 13.42 | 13.04 | 0.97 | 16.50 | 1.23 |
| feedback on mean x | 2.47 | 2.37 | 0.96 | 2.84 | 1.15 |
| sine + feedback together | 11.34 | 11.09 | 0.98 | 13.45 | 1.19 |

Attempts (accepted + rejected) and checkpoints taken: ours and H are identical (sine 15283 + 2874, 764
checkpoints; square 19125 + 1802, 956; feedback 2997 + 660, 149; both 14349 + 2466, 717). SciML: sine
15283 + 2873 (764), square 19257 + 1832 (962), feedback 2986 + 591 (149), both 14348 + 2462 (717).

## Correctness

The final state `u(T)` of StatefulAlgorithms is bit-identical to the hand-written loop in every case. SciML's
relative difference to it: sine 5.5e-4, feedback 3.8e-6, both together 7.9e-5. For the square pulse train the
force is discontinuous and is sampled once per step, so the state depends on the step sequence and `u(T)` of
two different step controllers is not comparable (relative difference 1.1); only its timing is meaningful.

## Limits

- This is a small kernel (about 0.65 microseconds per attempt), so per-step costs show up; a heavier right-hand side
  shrinks every ratio towards 1 (see `../ode`).
- The force is sampled once per step (zero-order hold) in all implementations. In SciML a force that depends only
  on time could instead sit inside the right-hand side, continuous in time; that is a different model and was not compared.
- Each run uses one fixed composition (a plan with its drives in a nested `Routine` when there are several); changing it
  means building a different plan, not changing it while it runs. Restoring a checkpoint into a changed setup was not tested.

## Modifiers: rewiring other internal variables without redefining structs

`modifiers.jl`, `run_modifiers.jl`. The integrator (`ChainDP5M`) is defined once and only exposes its internals as
variables (the parameters `par`, the tolerance `rtol`, the state `u`, a `stale` flag that says the first stage must be
recomputed). Modifiers are small algorithms that read and write those variables by name: `DampingRamp` (damping 1.0 to
0.8 over the run), `ToleranceSchedule` (rtol rising to 10x), `StateKick` (an impulse to oscillator 1 every 500 accepted
steps). No new struct is defined for an experiment, and which modifiers a run has is decided when the plan is built.
SciML does the same with callbacks that write into the mutable parameter (`i.p.par = ...`), the options
(`i.opts.reltol = ...`) and the state (`i.u`), each followed by `u_modified!`.

Loop time of the whole run (sine force, checkpoints every 20 accepted steps, t in [0, 4000]). "SciML time / ours" is
SciML's loop time divided by ours. The per-attempt columns are microseconds per attempt.

| modifiers | ours, loop ms | SciML, loop ms | SciML time / ours | ours, microseconds per attempt | SciML, microseconds per attempt |
|---|---|---|---|---|---|
| none | 11.86 | 14.21 | 1.20 | 0.653 | 0.783 |
| damping ramp | 12.29 | 15.53 | 1.26 | 0.653 | 0.825 |
| damping ramp + tolerance schedule | 11.10 | 14.56 | 1.31 | 0.654 | 0.858 |
| kick + damping ramp + tolerance schedule | 11.09 | 14.82 | 1.34 | 0.655 | 0.874 |

The package's cost per attempt does not move as modifiers are added (they are compiled into the loop); SciML's grows
with each callback it carries. The package's final state is bit-identical to the hand-written loop in every row;
SciML's differs from it by 5.5e-4, 2.0e-3, 1.5e-3 and 5.9e-3. (An earlier version let the damping fall to 0.5, which is
chaotic: the final states of different step controllers then differ by order 1, which is trajectory divergence and says
nothing about correctness, so the ramp now stops at 0.8.)

## Front end: what the user writes

Counted for the full experiment above (sine drive, checkpoints, three modifiers), with the library parts hidden:
for StatefulAlgorithms the integrator and the checkpointer, for SciML the solver. The right-hand side and the force
functions are shared on both sides and not counted. `frontend.jl` holds exactly this code and is run and checked
(`check_frontend.jl`).

The StatefulAlgorithms composition, in the DSL, is a block plus initialisation and the run:

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
| the experiment: composition, setup and run (drive, checkpoints and modifiers taken as ready-made components) | 14 (the 9-line block, 3 lines of setup and run, 2 of function wrapper) | 30 (the callbacks, the setup and the solve; there are no ready-made components) |
| plus defining the four components: `SineDrive` 4, `DampingRamp` 8, `ToleranceSchedule` 4, `StateKick` 8 | 14 + 24 = 38 | 30 (unchanged: the logic is in the callbacks) |

So the front end is shorter when the components exist and a little longer when the user writes them all. The difference is
in what is reusable: a component reads and writes variables by name (`par`, `stale`, `t`), so it works with any integrator that
exposes those names; a SciML callback is written against the structure of the problem (`i.p.par`, `i.opts.reltol`,
`u_modified!`). SciML callbacks can also be packaged as constructor functions, but they carry those field paths with them.
Rewiring an experiment in the package means adding or removing a line in the block; in SciML it means editing or adding callbacks
in the `CallbackSet`.
