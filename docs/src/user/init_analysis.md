# [Init Analysis](@id init_analysis_user)

`ContextAnalyser` is a lightweight, best-effort tool for discovering which
unresolved context values an entity's `init` and `step!` methods request.

It is meant for exploratory analysis, not for exact validation.
When an `init` path eventually errors because a missing value turned into `nothing`,
analysis stops for that path and only the accesses up to that point are recorded.

Use it when you are not sure which `Input(...)`, `Route(...)`, or `Share(...)`
values an algorithm needs. The analyzer runs your hooks with a recording context
instead of a normal runtime context.

## Loading It

The analyzer is included with the package and is available after loading
`StatefulAlgorithms`:

```julia
using StatefulAlgorithms
```

## Running Analysis

Use `analyse_inits` on a loop algorithm:

```julia
analysis = StatefulAlgorithms.analyse_inits(comp)
```

This resolves the loop algorithm, creates analyzer views with `view(...)`, and
tries the registered initialization hooks inside error-recording blocks. It does
not execute the real scheduler or reproduce the normal lifecycle exactly.

The analyzer records:

- which registered context entries were opened,
- which unseeded names each entry requested through `context.x`,
  `get(context, :x, default)`, `haskey(context, :x)`, or indexing,
- a compact count of captured errors,
- stored per-view inputs that were seeded or produced during successful `init` calls.

An access satisfied by a seeded or previously produced value is returned
directly and is not added to `requested_inputs`; that result describes missing
dependencies, not a complete trace of every property access.

## Analysing Steps

Use `analyse_steps` when you want to probe runtime reads as well:

```julia
analysis = StatefulAlgorithms.analyse_steps(comp)
```

By default this first runs the analyzer's init traversal and then attempts one
step-analysis pass for each registered step algorithm. This is a dependency
probe, not a scheduled loop iteration.

You can disable the init pass when you already have enough seeded state:

```julia
analysis = StatefulAlgorithms.analyse_steps(comp; init = false, inputs = (; ...))
```

Step analysis is still best-effort.
It is most useful for discovering direct reads from the view.
It does not try to perfectly reproduce every runtime routing/share writeback case.

## Seeding Inputs

You can pass per-view inputs with the `inputs` keyword:

```julia
analysis = StatefulAlgorithms.analyse_inits(
    comp;
    inputs = (;
        CaptureSeed_1 = (; seed = 4, scale = 2.0),
        DirectContextRead_1 = (; noise = 8.0),
    ),
)
```

These inputs are keyed by the registered context names, such as `:CaptureSeed_1`.

Within a view:

- `haskey(context, :x)` returns `true` when `x` was seeded for that view,
- `get(context, :x, default)` returns the seeded value,
- `context.x` returns the seeded value,
- successful `init` and `step!` return values are merged back into the analyzer's stored inputs.

That makes iterative analysis possible: seed what you already know, run analysis,
inspect what is still requested, then rerun with more inputs in place.

## Reading Results

The default display is intentionally compact:

```julia
println(analysis)
```

Use these helpers for programmatic access:

```julia
StatefulAlgorithms.requested_inputs(analysis)
StatefulAlgorithms.stored_inputs(analysis)
analysis.memory.errors
```

`requested_inputs(analysis)` returns a dictionary of:

```julia
view_key => Vector{Symbol}
```

showing which unresolved symbols that view requested during analysis.

## Structural Inspection

Use `inspect` for one report that combines resolved registry entries, routes,
shares, runtime `@input` declarations, the execution-plan tree, and the
best-effort init/step analysis:

```julia
report = inspect(comp)
report_without_steps = inspect(comp; steps = false)
```

`inspect` does not initialize a real `ProcessContext` or run the hot loop. Its
analysis sections do call user `init` and `step!` methods with recording views.
Those hooks can still mutate captured objects or cause external side effects,
so do not use analysis on effectful hooks when read-only behavior matters. The
analysis sections have the same best-effort limitations as `analyse_inits` and
`analyse_steps`; treat the report as a structural diagnostic, not proof that
runtime behavior is valid.

## Printing Events

Event traces are not printed by default.
Print them explicitly with:

```julia
StatefulAlgorithms.printevents(analysis)
```

This prints the recorded `view`, `getproperty`, `get`, `haskey`, and `getindex` events in order.

## Forms That Analyse Well

The analyzer only sees what goes through the context/view surface.
These forms work best:

- required reads through `context.x` or destructuring like `(; x, y) = context`
- optional reads through `get(context, :x, default)`
- explicit presence checks through `haskey(context, :x)`
- explicit indexed reads like `context[:OtherAlgo_1]` or `context[algo_ref]`
- `@StepAlgorithm ... @inputs((; ...))` for init-only requirements
- `step!` methods that return plain `NamedTuple`s with stable output names

These forms are harder to analyse accurately:

- dynamically constructed property names or keys
- reads from globals, closures, captured mutable state, files, or random external sources
- control flow where a missing value quickly becomes `nothing` and errors before later accesses happen
- step paths that depend on exact routed writeback behavior across subcontexts

If you want better analysis results, prefer direct view reads over indirect lookup logic.

## Typical Workflow

1. Run `analyse_inits(comp)` once.
2. Inspect `StatefulAlgorithms.requested_inputs(analysis)`.
3. Seed the next round with `analyse_inits(comp; inputs = ...)`.
4. Repeat until the interesting init paths stop asking for unknown values.
