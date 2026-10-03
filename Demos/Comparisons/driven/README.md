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
3. **Front-end code, counted in tokens.** (Line counts are misleading: the SciML callbacks are written with `->` and `;`, one
   statement-rich line each; tokens ignore layout.) The experiment is a 9-line DSL block, 171 tokens with setup and run, when the
   components exist, against 432 tokens of callbacks and setup in SciML (2.5 times). Counting every component the package version
   needs (the drive, three modifiers and the checkpointer, 231 tokens) it is 402 tokens against 432. The package's components are
   reusable because they refer to variables by name; a SciML callback is written against the problem's structure (`i.p.par`,
   `i.opts.reltol`, `u_modified!`).
4. **Nothing has to be decided in advance in the package, and in SciML the choice does cost something in some loops.** An
   integrator can return all its state and parameters as variables from the start; twelve extra unread variables cost 0.4 to
   1.1% (noise level). SciML needs everything a later experiment may change to be a field of a mutable parameter struct,
   decided up front. Parameters that are only read cost little (0 to 9%). State that is written and read on every iteration
   in a mutable container costs 2.1 to 2.4 nanoseconds per iteration, 1.25 to 2.9 times the loop time, as soon as the loop
   hands that container to a call (a callback, a logger); the same state held as an immutable value threaded through the loop,
   which is how the package passes values in the context, costs nothing in every scenario tested.
5. **Limits are listed at the end**: the integrator and checkpointer counted as library, a small kernel, SciML's slightly
   different step counts, noise of about 2%.

## How to run

```bash
julia --project=Demos/Comparisons/driven -e 'using Pkg; Pkg.instantiate()'     # first time only
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run.jl                # one force at a time
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/run_modifiers.jl      # modifiers on internals
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/check_frontend.jl     # runs the counted front-end code
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/shared_state_example.jl  # a component that reads another's state
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/never_fires.jl         # cost of items that never fire
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/unique_overhead.jl    # the Unique() cost
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/unread_variables.jl   # cost of exposing everything
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/mutable_cost.jl       # cost of a mutable parameter struct
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/mutable_cost_coupled.jl  # ... with several coupled systems
julia --project=Demos/Comparisons/driven Demos/Comparisons/driven/escaping_state.jl     # mutable state that escapes, written every iteration
```

Files (the extra scripts are listed above): `scenario.jl` (system, force shapes, constants), `hand.jl` (hand-written reference), `framework.jl` (the package:
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
| noise + kick + damping ramp + tolerance schedule (the noise modifier has its own RNG state, added last) | 11.15 | 14.98 | 1.34 | 0.658 | 0.884 |

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

Size is counted in source tokens (identifiers, literals, operators, keywords, brackets; whitespace and comments ignored; `code_size.jl`),
not lines, because lines depend on how much is packed onto one line. The integrator is not counted for the package: SciML provides its
solver, so counting `ChainDP5M` would not be like for like. The checkpointer is counted on both sides: SciML has no stock equivalent
(its checkpoint callback is inside the 432 tokens below), so the package's `Checkpointer` is user-written too.

| what the user writes | StatefulAlgorithms, tokens | SciML, tokens | SciML / package |
|---|---|---|---|
| the experiment: composition, setup and run (the drive, checkpointer and modifiers as ready-made components) | 171 | 432 (callbacks, setup, solve) | 2.5 |
| plus the five components: `SineDrive` 31, `DampingRamp` 57, `ToleranceSchedule` 21, `StateKick` 55, `Checkpointer` 67 | 171 + 231 = 402 | 432 (unchanged: the logic is in the callbacks) | 1.07 |

In lines the same code is 14, and 45 with the components, against 30 for SciML, which suggested the package is longer; in tokens it is
shorter or equal. The package is much shorter when the components exist and about equal when the user writes them all; the difference is
reuse. A component reads and writes variables by name (`par`, `stale`, `t`), so it works with any integrator that exposes those names; a SciML
callback carries the structure of the problem with it. SciML callbacks can be packaged as constructor functions, but they keep those
field paths.

## What has to be decided in advance

**SciML.** Anything a later experiment may change has to live in the parameter struct, which then has to be mutable (or in the
integrator's options). In this demo the SciML first experiment already had `mutable struct ChainPm; par; F; end` (the
callback-based force needs `F` writable and `par` sits in the same struct), so the three modifiers needed only 195 more tokens of callbacks (kick 57, ramp 97, tolerance 41) and no struct change; this flatters SciML. An experiment that kept the sine force inside the
right-hand side with an immutable `p` would have had to turn it into a mutable struct holding every field that might later change.

**StatefulAlgorithms.** The first integrator (`ChainDP5`) happened to have the parameters and the tolerance as constants, so
adding the modifiers meant rewriting it as `ChainDP5M` with `par`, `rtol` and `stale` as managed variables (28 more tokens, 207 to 235). That was a choice, not a requirement: an integrator can return all its state and parameters as variables from the
start, and variables that nothing reads cost nothing at run time. `unread_variables.jl` checks this: the same integrator with
twelve extra variables of mixed types (scalars, arrays, a NamedTuple) that nothing reads runs at 1.011, 1.004 and 1.006 times
the loop time of the minimal one (3 to 7 nanoseconds per attempt, the noise level of these runs) with identical results.
Compile time was not measured.

**What a mutable parameter struct costs** (`mutable_cost.jl`, `mutable_cost_coupled.jl`). The same chain, the sine force computed from `t` inside the
right-hand side so nothing writes into `p`, with the parameters in an immutable versus a mutable struct. The only difference
is what the type lets the compiler do. "mutable / immutable" is the loop time with a mutable `p` divided by the loop time with
an immutable `p`, same implementation and same right-hand side; the range is over two runs. Immutable p, microseconds per
attempt: SciML 0.625 to 0.639, hand-written 0.643 to 0.658.

| right-hand side reads p | SciML, mutable / immutable | hand-written loop, mutable / immutable |
|---|---|---|
| once, at the top | 1.000 to 1.004 | 0.999 to 1.024 |
| inside the loop (`p.par.a * x` and so on) | 1.037 to 1.056 | 1.017 to 1.029 |

A mutable struct is free when its fields are read once before the loop. Read inside the loop it cost 2 to 6% on this
kernel; the cause was not investigated (an explanation in terms of aliasing was a guess and is not supported by the
coupled-systems results below). Results are identical in both cases. For comparison, each further callback in the modifiers
table adds 0.02 to 0.04 microseconds per attempt (2.5 to 5% of 0.78).

**Several coupled systems** (`mutable_cost_coupled.jl`). M chains of 64 oscillators coupled in a ring, each chain with its own
parameter struct (a, b, c, gamma and a coupling kappa to the previous chain), in a tuple; the right-hand side reads the fields
inside the loop the natural way. Hand-written Dormand-Prince loop, nothing writes into the parameters. Time per attempt is
microseconds; the ratio is the loop time divided by the loop time of the immutable structs reading inside the loop, same M.
The coupled-systems version of the right-hand side has an inner loop over sites that reads five parameters and the neighbouring
chain.

| parameters | M = 1: microseconds per attempt | M = 1: time / immutable | M = 4: microseconds per attempt | M = 4: time / immutable | M = 8: microseconds per attempt | M = 8: time / immutable |
|---|---|---|---|---|---|---|
| immutable structs, reads in the loop | 0.529 | 1.000 | 2.084 | 1.000 | 4.138 | 1.000 |
| mutable structs, reads in the loop | 0.525 | 0.992 | 2.095 | 1.005 | 4.146 | 1.002 |
| mutable structs, fields copied to locals first | 0.535 | 1.012 | 2.091 | 1.004 | 4.151 | 1.003 |
| one `Vector{Float64}` of parameters, reads in the loop | 0.531 | 1.003 | 2.100 | 1.008 | 4.155 | 1.004 |
| one `Vector{Float64}` of parameters, copied to locals | 0.538 | 1.017 | 2.101 | 1.008 | 4.142 | 1.001 |

In these runs a mutable struct or a plain `Vector{Float64}` of parameters that is only read costs nothing measurable, and hoisting the fields into
locals changes nothing, so no function barrier or argument threading was needed to avoid a cost for read-only parameters. State that is
written in the loop behaves differently: see the next section. The single-chain result above
(2 to 6%) shows the cost is not zero in every kernel; I could not reproduce it with coupled systems, and kernels where the compiler
cannot hoist or vectorize through the parameters may behave differently.

**Static versus dynamic structure.** My first version of the `Vector{Float64}` case looped over the systems at run time with run-time
offsets, while the struct versions were unrolled over the systems with compile-time offsets (a recursion over the tuple). That version
was 1.33 times slower at M = 1, 4 and 8, with or without hoisting the parameters. Giving the `Vector` version the same static unrolling
(the table above) removed the whole difference, so the gap was the loop structure, not the parameter container. Which part of the structure
(the constant offsets, the unrolling) matters was not isolated.

## What the claim is, and what it is not

The claim is not that mutable state is free in the package. A monolithic hand-written loop that keeps all its state as locals
compiles to the same code the package produces, and so does any simulation written with its shared state spelled out for one
known composition. What the package avoids is having to write that: each component declares its own state, and when the
components are composed the compiler produces the loop a hand-written monolith would have been. So the comparisons that matter are
(a) speed against the hand-written monolith, (b) speed against other ways of composing reusable parts, which share state through
mutable containers or callbacks, and (c) what has to be edited to change the composition. (a) and (b) are in the tables above:
0.96 to 0.98 times the monolith, against 1.15 to 1.34 times for SciML callbacks. (c) is next.

## Adding a component that has its own state

`run_modifiers.jl` now has a fifth combination. `NoiseKick` is a new modifier with an internal state that it writes (its own RNG)
and that also writes the integrator's state (`u` and `stale`). It was added last, to all three implementations, after everything else
was written. Edits are counted from a diff of `modifiers.jl` before and after (the shared constant and `using Random` are not
counted).

| implementation | existing code edited | new code added, in tokens | where |
|---|---|---|---|
| hand-written monolith | 2 lines (the function signature, and the line that declares the locals) | net growth of the loop by 61 tokens (4 lines added inside the loop body) | the loop that every composition shares |
| StatefulAlgorithms | none | 108: the component 88, plus the line in the composition block 20 | a new algorithm and a name in the block |
| SciML callbacks | none in the builder that selects subsets (a `push!`); 1 line in a fixed experiment (the `CallbackSet(...)` argument list, 2 tokens) | 87: the callback 85 (its own RNG is a closure variable), plus 2 | a new callback in the callback list |

Both SciML and the package define the new component (the callback is SciML's component). In tokens the callback (85) is about the size of
the package's algorithm (88), which spells out its managed state and its return value, and the package adds 20 more to place it in the
block, so for this modifier SciML is a little shorter (87 against 108); the monolith is shortest at 61, and the only one that edits the
existing loop. The package version is bit-identical to the hand-written loop (final state difference 0) and runs at 0.98 times its loop time;
SciML at 1.31 times (last row of the modifiers table). Both composition styles are additive: existing components are not touched. What
differs between the package and SciML is the run-time cost of each added callback (0.016 to 0.042 microseconds per attempt) and how a
modifier refers to the integrator (`integ.u`, `integ.stale` by name, against `i.u`, `i.p`, `u_modified!`).

**A new component that reads another component's state** (`shared_state_example.jl`, runs all three variants). `GrowingKick` kicks with
a size that grows with the number of checkpoints taken so far, which is the checkpointer's own state (its list `snaps`).
In the package it is one new algorithm (68 tokens) and one new line in the block (26 tokens), `GrowingKick(..., snaps = ckpt.snaps)`; the checkpointer is
not touched. In SciML the checkpoint callback keeps `snaps` as a local variable; a new callback can read it in two ways. Written in one
function (version A, a 68-token callback), both callbacks capture the same local, which needs no edit of the checkpoint callback but ties the two together
in that scope. Written as reusable functions that each return a callback (version B), the checkpoint constructor has to be changed to
hand its list out (`return cb, snaps`) and its call site to receive it. Both give the same result (15318 accepted steps, 765
checkpoints; SciML within 3.6e-4 of the package). A quantity that must enter the right-hand side is different: it needs the
right-hand side and the parameter struct changed in the package and in SciML alike (`par` for the package, `p` for SciML); an
earlier version of this section said SciML would need a field added to `p` where the package would not, which was not supported
and is withdrawn.

## Items that run every time versus items that are scheduled

SciML evaluates the condition of every `DiscreteCallback` after every accepted step, whether or not the callback fires; only
the affect is conditional. `never_fires.jl` adds K items that never do anything to the base experiment (sine drive and checkpoints):
K callbacks whose condition is false in SciML, K components of distinct types scheduled at an interval of one million iterations
in the package. Loop time only; "extra, microseconds per attempt" is the difference to the same implementation with K = 0.

| extra items that never fire | ours, microseconds per attempt | ours, extra | SciML, microseconds per attempt | SciML, extra |
|---|---|---|---|---|
| 0 | 0.662 | 0.000 | 0.794 | 0.000 |
| 2 | 0.664 | 0.002 | 0.834 | 0.040 |
| 4 | 0.656 | -0.006 | 0.839 | 0.045 |
| 8 | 0.657 | -0.005 | 0.894 | 0.100 |

A never-firing callback costs SciML about 0.012 microseconds per attempt (its condition, once per step); a scheduled component that does
not run costs the package nothing measurable. Two caveats. A package schedule counts loop iterations (attempts, accepted or
rejected), so a cadence in accepted steps (a checkpoint every 20 accepted steps) is written as a component that runs every
iteration and checks inside (`nacc != last && nacc % 20 == 0`), which is the same per-step test as a callback condition and is
what the checkpointer and the kick modifiers here do. And a SciML condition can be any predicate on the state, which the interval
schedule cannot; the package would use a component that checks the predicate itself.

A note on `Unique(...)`, which looked like a per-iteration cost in an earlier version of this section and is not (`unique_overhead.jl`). `Unique`
creates a random id that becomes a type parameter, so each call makes a new type, and a plan built with a fresh `Unique` is compiled the first
time it runs. A benchmark that builds a fresh `Unique` for every repetition therefore times that compilation: about 110 to 130 milliseconds on this
plan, which spread over the ~18 000 attempts of a run looks like 4 to 5 extra microseconds per attempt. With one `Unique` instance reused across
repetitions the loop is unchanged (extra 0.002 to 0.004 microseconds per attempt, noise), and a plan with an already compiled type runs its first
run in 12 milliseconds. Reusing the instance, or giving the algorithm a fixed id so that its type is the same every time
(`IdentifiableAlgo(f; id = some_fixed_uuid)`: 12 milliseconds on every construction, against 111 for a fresh `Unique`), avoids the compile. The experiments in
this folder do not use `Unique`.

## State in a mutable container: when it costs something

`escaping_state.jl`. The experiments above read parameters and never wrote the state they depend on inside the loop, and
their containers could be optimised away. This one is built to make the container matter. It measures the alternative to threading
values (state shared through mutable containers that other code is handed); it does not claim the package gets mutability for free,
only that it does not need the shared state to be spelled out in advance (previous section). Julia can only replace a mutable
object by registers when the optimizer sees its whole lifetime, that is when it does not escape
([Julia escape analysis](https://docs.julialang.org/en/v1/devdocs/EscapeAnalysis),
[why SVector is faster than MVector](https://discourse.julialang.org/t/why-is-svector-faster-than-mvector/55174)), so every container
here is created by the caller and passed to a `@noinline` loop function: it escapes. A variable `x` is updated on every iteration
(`x = kernel(x, c, i)`, so each iteration depends on the previous one) at three kernel weights, tiny (1.2 nanoseconds per
iteration), small (4.1) and medium (8.0 to 8.7), in these containers: a plain local (registers, the baseline), the immutable value
threaded through the loop (`s = State(kernel(s.x, s.c, i), s.c)`, the way the package passes context values), a mutable struct that does
not escape, a `Base.RefValue{Float64}`, a whole mutable struct, an immutable struct with a `RefValue` field, and an immutable struct with a one-element
`Vector{Float64}` field. Each is run with four things the loop may also do on every iteration. Times are nanoseconds per iteration;
"/ local" is the time divided by the plain local's time in the same scenario and weight. Results are identical in every case.

**Where it costs.** The loop calls a function that is handed the state (a logger, a callback): the value for the local and
threaded cases, the container for the others, so the compiler must store the new `x` before the call and reload it after.

| container of `x`; the loop calls a function handed the state | tiny, ns per iteration | small, ns per iteration | medium, ns per iteration | tiny / local | small / local | medium / local |
|---|---|---|---|---|---|---|
| local variable (registers) | 1.25 | 4.16 | 8.67 | 1.00 | 1.00 | 1.00 |
| immutable value threaded through the loop | 1.24 | 4.17 | 8.67 | 0.99 | 1.00 | 1.00 |
| mutable struct, not escaping (compiled away) | 1.22 | 4.19 | 8.73 | 0.98 | 1.01 | 1.01 |
| `Base.RefValue{Float64}`, escaping | 3.60 | 6.63 | 10.81 | 2.89 | 1.59 | 1.25 |
| whole mutable struct, escaping | 3.61 | 6.70 | 10.96 | 2.90 | 1.61 | 1.26 |
| immutable struct with a `RefValue` field | 2.69 | 6.43 | 10.97 | 2.16 | 1.55 | 1.27 |
| immutable struct with a one-element `Vector{Float64}` field | 2.34 | 6.50 | 11.25 | 1.88 | 1.56 | 1.30 |

The extra cost is a fixed 2.1 to 2.5 nanoseconds per iteration (store, call, reload: the next iteration waits for the memory round trip),
so it is 1.25 times the loop at 8.7 nanoseconds per iteration and 2.9 times at 1.25. Per-step kernels of 1 to 10 nanoseconds are
the regime of Monte Carlo sweeps and cheap protocols.

**A second case.** State held in a one-element `Vector{Float64}` while the loop also stores into another `Vector{Float64}`
(for example a recorded trace): two arrays of the same element type may alias, so the value is written and reloaded every iteration.

| container of `x`; the loop also stores x into an array | tiny, ns per iteration | small, ns per iteration | medium, ns per iteration | tiny / local | small / local | medium / local |
|---|---|---|---|---|---|---|
| local variable (registers) | 1.17 | 4.15 | 8.20 | 1.00 | 1.00 | 1.00 |
| immutable struct with a one-element `Vector{Float64}` field | 2.52 | 5.52 | 11.06 | 2.16 | 1.33 | 1.35 |

**Where it does not cost** (the same containers, ratios to the local in the same scenario, range over the three weights):
- nothing else in the loop: 0.99 to 1.01 for the `Ref`, the mutable struct and the struct with a `Ref` field (the one-element
  `Vector` varied, 0.99 to 1.19 across runs);
- the loop stores into an array: 1.00 to 1.02 for the same three;
- the loop calls a function the compiler can see does not touch the container (it only writes an array passed to it):
  0.94 to 1.00;
- the immutable value threaded through the loop: 0.98 to 1.02 in every scenario above, which is the package's way of passing values;
- a parameter that is read on every iteration and written every 4096 iterations, in any of the containers and any of the four
  loop variants: 0.86 to 1.09 (about 6 to 9% at the medium weight, none at the tiny and small weights).

Two things were left out on purpose. An abstract `Ref{Float64}` field type (a known type-instability mistake, not a property of
mutable containers) was measured at 3.5 to 26 times slower and is not part of the comparison. And these are single-variable
kernels; with the state of several coupled systems in mutable containers that are handed to code in the loop, the extra
cost would be paid for each round trip.

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
