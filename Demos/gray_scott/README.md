# Gray–Scott, live

An interactive reaction–diffusion playground. The simulation is a StatefulAlgorithms process;
the window is a thin client of it.

```bash
julia -t auto --project=Demos/gray_scott -e 'using Pkg; Pkg.instantiate()'   # first time only
julia -t auto --project=Demos/gray_scott Demos/gray_scott/run_sa.jl         # StatefulAlgorithms backend
julia -t auto --project=Demos/gray_scott Demos/gray_scott/run_bespoke.jl    # hand-written backend
```

| | |
|---|---|
| drag on the canvas | paint chemical V (a fading trail shows where you drew) |
| right-drag / shift-drag | erase |
| click or drag the regime map, sliders | change feed/kill/speed live; patterns morph |
| preset buttons | jump to a regime and reseed (spots cannot grow into stripes) |
| Pause | stops the process; you can still paint, Resume continues from your edit |

## Files

```
gray_scott.jl               the window: interface only, no simulation, does not know its backend
gray_scott_definitions.jl   backend 1: the StatefulAlgorithms steps and process, plus control functions
gray_scott_bespoke.jl       backend 2: hand-written loop with the same control surface, no package
run_sa.jl, run_bespoke.jl   entry points: load a backend, then the window
bench/                      benchmarks of the two backends
```

`gray_scott_definitions.jl` defines three `@StepAlgorithm`s (`Edit`, `GrayScott`, `Pace`)
and a `@CompositeAlgorithm` over one `@state`. `feed`, `kill` and the speed are `Interactive`
variables; `modify!(f, process)` queues an edit `f(U, V)` that runs between two physics steps.
`gray_scott.jl` only calls those, and does its own painting.

The dashed line on the map is the saddle-node curve `k = √f/2 − f`; above it no pattern survives.
