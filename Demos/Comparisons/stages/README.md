# A multi-stage experiment in the manuscript style: StatefulAlgorithms vs SciML

The manuscript experiments (field sweeps, pulses, FORC, anneals) share a structure: a *core* (the dynamics and its loggers) is
built once and reused by every *stage*; each stage adds its own *protocol* that writes a variable of the dynamics; the experiment
is a `@Routine` of repeated stages (`@repeat n stage()`), and a sweep reruns it for several values of a parameter. This demo has
that structure on a chain of 64 nonlinear oscillators, treated as a toy ferroelectric (double-well on-site potential, harmonic
coupling, damping 1.0) under a swept uniform field `E`:

| stage | field E | steps |
|---|---|---|
| 1, preset | 0 to +Emax | 4000 |
| 2, down | +Emax to -Emax | 8000 |
| 3, up | -Emax to +Emax | 8000 |
| 4, return | +Emax to 0 | 4000 |

Fixed time step 0.05 (so a stage is a number of steps), fixed-step Dormand-Prince 5. Logged: the polarization `P = mean(x)` on
every step and the pair `(E, P)` every 50 steps. The whole experiment is run for four maximum fields Emax = 0.5, 0.6, 0.7, 0.8
(a sweep); the timings are the loop time summed over the sweep (96000 steps).

```bash
julia --project=Demos/Comparisons/stages -e 'using Pkg; Pkg.instantiate()'     # first time only
julia --project=Demos/Comparisons/stages Demos/Comparisons/stages/run.jl
```

Files: `scenario.jl` (system, stage table, shared helpers), `hand.jl` (hand-written monolith), `framework.jl` (the package, in the
DSL), `sciml.jl` (SciML with callbacks), `run.jl` (harness). Only the loop is timed; integrators, processes and buffers are built first.
Implementations are interleaved; each value is the minimum over 7 rounds. Julia 1.13.1, load average 3-6, noise about 2%.

## The three implementations

- **StatefulAlgorithms (`framework.jl`):** the core is one composite, `integ` (the integrator, which owns the field `E`, the
  parameters `par` and a `stale` flag), the polarization logger every step, and the `(E, P)` logger `@every 50`. Each stage is a
  composite that includes the core with `@context c = core()` and adds its own protocol, a `FieldRamp` that writes `c.integ.E`. The
  experiment is `@Routine begin @repeat n1 stage1(); @repeat n2 stage2(); ... end`. Components: `ChainFixed` (11 lines), `Polarization`
  (4), `FieldLoop` (4), `FieldRamp` (10).
- **SciML (`sciml.jl`):** one fixed-step solve (`adaptive = false`), the field in a mutable parameter that a callback writes after each
  step from a stage table, and two callbacks for the loggers.
- **Hand-written (`hand.jl`):** one loop over the stage table, everything a local.

## Results

"time / monolith's" is the loop time divided by the hand-written monolith's (H = 1.00). "SciML time / ours" is SciML's loop time
divided by the loop time of StatefulAlgorithms.

| implementation | loop, ms | nanoseconds per step | time / monolith's |
|---|---|---|---|
| H hand-written monolith | 51.85 | 540.1 | 1.00 |
| P StatefulAlgorithms | 51.42 | 535.6 | 0.99 |
| S SciML | 69.73 | 726.3 | 1.34 |

SciML time / ours is 1.36. After the change described below the three are 52.52 / 51.50 / 74.34 ms (547.1 / 536.5 / 774.4
nanoseconds per step), 1.00 / 0.98 / 1.42 times the monolith, and SciML time / ours is 1.44.

Correctness: the package's final states, its 24000-entry polarization trace and its 480 `(E, P)` pairs are identical to the monolith's
for every Emax, before and after the change. SciML's final states differ by 1.1e-12 (relative); its trace has 24001 entries because the
fixed-step solver takes one more, tiny, closing step (a floating-point effect on the end time), and its first 24000 entries equal the
monolith's; its pairs are identical.

## Changing the experiment afterwards

The change made after everything above was written: **in stage 2 only, the damping ramps from 1.0 to 0.6 and stays there** (a second
protocol writing the parameters). The package's integrator already exposed its parameters (`par`) and a `stale` flag from the
start, so it needed no change. Edits counted from a diff of each file before and after (raw diff lines):

| implementation | existing lines changed or removed | lines added | where |
|---|---|---|---|
| hand-written monolith | 5 | 8 | inside the loop: the loop header, the parameter used by the step, the recompute condition, and a stage-2 branch |
| StatefulAlgorithms | 0 | 15 (13 of them code: the component 10, an instance 1, an alias 1, a call 1) | a new `GammaRamp` component, and two lines in the stage 2 composite |
| SciML | 1 (the `CallbackSet(...)` list) | 10 | a new callback |
| shared helper (`gamma_after`, used by the monolith's check and SciML) | 0 | 4 | `scenario.jl` |

The damping ramp changes the dynamics (the trace sum goes from 3430.4 to 3447.6 and the final polarization differs).

## Code size, honestly

Counted as non-comment, non-blank lines of what the user writes:

| | StatefulAlgorithms | SciML |
|---|---|---|
| the experiment: stages, core, routine, loggers and protocols | 44 (`framework_experiment`, after the change) | 26 (`sciml_setup`, after the change; 16 before) |
| the components it uses (integrator, two loggers, ramp) | 29, plus 10 for the damping ramp | none: logic is in callbacks inside the 26 |

For a sweep whose stages all have the same shape (a ramp between two values over n steps), a stage table is more compact than four stage
composites: the SciML and hand-written versions are driven by `stages(Emax)` and a one-line change adds a stage, whereas the
package version spells each stage out (about six lines per stage). The package's explicit structure pays when the stages differ: a stage
with another protocol, its own logger or an extra component is a composite with one more line, as the damping ramp was, without a
common schema to extend. The table-driven versions would need a new column or a branch.

## Not tested

Sweeping a parameter inside one process (here each Emax is a separate process), stages of different lengths in time on an adaptive integrator
(`@repeat Until(...)` exists for that), and interactive use.

## Notes on running it

Julia 1.13.1 prints an internal compiler error while inferring `flatten_comp_funcs` for this nested plan ("irinterp is unable to handle heavy
recursion correctly"); the program continues and runs correctly, at the speed in the table. This is being investigated separately.
