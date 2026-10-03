# Ising Metropolis: StatefulAlgorithms vs hand-written loop vs structs vs SciML

Same kernel (`kernel.jl`: 2D Ising, L = 32, periodic, Int8 spins, one single-spin Metropolis
flip per step) wrapped four ways. Every variant draws the same random numbers in the same order
and must return an identical summary; `run.jl` checks that before timing anything.

```bash
julia --project=Demos/Comparisons/ising -e 'using Pkg; Pkg.instantiate()'          # first time only
julia --project=Demos/Comparisons/ising Demos/Comparisons/ising/run.jl 1 20000000 7       # workload 1, N steps, rounds
julia --project=Demos/Comparisons/ising Demos/Comparisons/ising/run.jl 2 20000000 7       # workload 2
julia --project=Demos/Comparisons/ising Demos/Comparisons/ising/run.jl 1 20000000 5 "A  hand,D2"   # subset by name
```

Timing: variants interleaved round-robin, minimum over the rounds, CPU time next to wall time,
bytes allocated per step. Run it on a quiet machine; the numbers below were taken at load average 3-6.

## Workloads

1. `workload1.jl`: annealed temperature, one flip per step. Variants:
   A hand-written loop (state local); A2 same, state built by the caller; B1/B2 structs (mutable `T`
   field / `T` passed by value, everything `@inline`); C/C2 StatefulAlgorithms (`Anneal` routed into
   the Metropolis algorithm; C2 with the `@inline` opt-in); D1/D1b/D2 SciML `FunctionMap` (`solve`, `init`+`step!`, callback writing `T`).
2. `workload2.jl`, modelled on the manuscript experiments: a protocol sets `T` (anneal) and `h`
   (sine pulse) every step, one flip, a logger pushes the running magnetisation every step, a
   diagnostics logger pushes mean/top-row magnetisation and energy every K = 1000 steps. Variants:
   A hand-written, B structs, C a `CompositeAlgorithm` of five pieces wired with `Route`, D SciML with three
   callbacks (SciML skips callbacks at the end of `tspan`; the last step's logging is applied by hand).

## Head-to-head: StatefulAlgorithms vs SciML

"SciML time / ours" is SciML's time per step divided by the time per step of StatefulAlgorithms with the
`@inline` opt-in (C2), so 7.4 means SciML takes 7.4 times as long as StatefulAlgorithms. SciML is the best
form of the three tried (`FunctionMap`, no saving, the protocol computed inside the right-hand side for
workload 1, three callbacks for workload 2).

| workload | StatefulAlgorithms C2, ns per step | SciML FunctionMap, ns per step | SciML time / ours |
|---|---|---|---|
| 1: annealed T, one flip per step | 8.4 | 62 to 67 (36 and 49 in two other runs) | 4.3 to 8.0 (typically 7.4) |
| 2: protocol + loggers (manuscript style) | 12.9 | 156 to 167 | 12 to 13 |

## All variants, ns per step

"time / A" is the variant's time divided by A's time (A = hand-written loop; below 1.00 is faster than A).
Julia 1.13.1, load average 3-6, minimum over 7 interleaved rounds.

| variant | workload 1: ns per step | workload 1: time / A | workload 2: ns per step | workload 2: time / A |
|---|---|---|---|---|
| A hand-written loop | 8.4 | 1.00 | 12.8 | 1.00 |
| B structs (all `@inline`) | 8.4 | 1.00 | 13.1 | 1.03 |
| C StatefulAlgorithms, default | 9.4 | 1.12 | 13.7 | 1.07 |
| C2 StatefulAlgorithms, `@inline` opt-in | 8.4 | 1.00 | 12.9 | 1.01 |
| D SciML FunctionMap, best of 3 forms | 62 | 7.4 | 167 | 13.1 |

## The ~1 ns gap in C, and the opt-in

`@StepAlgorithm` generates a hidden implementation function (`##Name_impl#n`) that `step!` calls,
and Julia decides whether to inline it. Its inliner is a static, size-based cost model with no
knowledge of loop frequency. Small bodies inline anyway and large ones amortise the call (and are
compiled once and reused by every plan), but a medium hot kernel like a single-spin Metropolis
update (an RNG range draw, four `mod1`, a second draw, an `exp`) is over the threshold and pays about
1 ns per step for the call (12% of the step).

`bisect.jl` narrows it down (one algorithm, constant T: the gap is the same for a bare
`InlineProcess`, a one-child composite and a Routine; a heap counter like `inc!(process)` adds
0.08 ns) and `ir.jl` shows the call in the optimized IR of `run(ip)`. Writing `@inline` on the
function (`@StepAlgorithm @inline function ...`) forces the body into the plan's step: the C2 column.
The cost is compile time: a forced body is compiled again inside every plan that uses it.

## Files

```
kernel.jl, workload1.jl, workload2.jl   the shared kernel and the variants
run.jl                                  correctness check + interleaved timing
bisect.jl, ir.jl                        diagnostics for the C gap
```
