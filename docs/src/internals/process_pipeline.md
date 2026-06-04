# [Process Pipeline Internals](@id process_pipeline_internals)

This page documents the runtime path from loop algorithm construction to loop
execution.

## 1. Construction

`Process(func, inputs_overrides...; repeats, lifetime, timeout)` (`src/Process.jl`):

1. Wrap bare `ProcessAlgorithm` as a one-child `CompositeAlgorithm`.
2. Normalize stop behavior: `repeats = n` becomes `Repeat(n)`, `lifetime` accepts `Lifetime` objects, and `Routine` defaults to `Repeat(1)` when no lifetime is provided.
3. Resolve the loop algorithm when needed.
4. Run lifecycle `init(algo, specs...; lifetime)` unless an initialized context is already provided.
5. Store the algorithm and its current runtime context on the process.

There is no `TaskData` layer. The initialized loop algorithm carries the
persistent context plus stored init/override specs. `Process` keeps its current
context separately so pausing can preserve a suspended runtime context without
rebaking it into the algorithm.

## 2. Init Phase

`init(la::LoopAlgorithm, specs...)` (`src/LoopAlgorithms/RuntimeInputs.jl`) applies:

1. Resolve `Init`/`Override` specs through the registry.
2. Merge passed specs over stored specs per target.
3. Build a fresh persistent `ProcessContext` with `algo` and `lifetime` in `_runtime`.
4. Merge `Init` values into target subcontexts.
5. Run `init(algo, input_context)`.
6. Merge `Override` values after init.
7. Return a loop algorithm with stored context, inits, and overrides.

For loop algorithms, `init(::LoopAlgorithm, ::ProcessContext)` iterates all registry entities in order (`src/LoopAlgorithms/Init.jl`).

`partialinit(la, specs...)` uses the same target resolution but only rebuilds
the targeted subcontexts.

## 3. Running

`run(p; kwargs...)` (`src/ProcessInteraction.jl`) calls `makeloop!` (`src/Process.jl`).

`makeloop!`:

- validates runtime keyword arguments against the loop algorithm's `@input` metadata,
- passes the persistent context to `loop`,
- passes runtime inputs as a positional `NamedTuple` to `loop`,
- spawns the loop task.

`run(la::LoopAlgorithm; kwargs...)` runs an initialized loop algorithm directly
and returns a loop algorithm with the next persistent context.

## 4. Loop Bootstrap and Runtime Inputs

The loop wrappers in `src/Loops.jl` merge runtime inputs before the while/for
loop:

```julia
loop(process, algo, context, lifetime, inputs)
```

The loop injects `process` and `lifetime` into the transient `_runtime` field.
An empty input tuple is a no-op. A non-empty tuple is merged into the transient
`ProcessContext._input` field. The bootstrap/first step may change the
transient context type. After bootstrap, steady-state steps must preserve
context type.

Repeat and indefinite loops are defined in `src/Loops.jl`; generated loops live
in `src/GeneratedCode/GeneratedLoops.jl`.

High-level structure:

1. `before_while(process)`
2. one unstable/bootstrap step
3. repeat/while body with stable step calls
4. tick/index increments
5. `after_while(process, algo, context, stored_context)`

Step bodies are produced by `step!_expr` (`src/LoopAlgorithms/GeneratedStep.jl` and `src/Identifiable/Step.jl`) so composite/routine structures can be unrolled and specialized to concrete algorithm/context types.

## 5. Cleanup Behavior

`after_while` (`src/Loops.jl`) does:

- paused process: store the suspended runtime context as a side effect, but compute the task result from the stripped persistent context shape.
- interrupted or indefinite: strip runtime-only fields before computing the task result.
- natural finite completion: store `cleanup(func, context)` stripped back to persistent context shape, then compute the task result.

Finished `Process`, `InlineProcess`, and direct `run(la::LoopAlgorithm)` paths
store contexts that may be absorbed back into an algorithm, so runtime-only
fields such as `_input`, `process`, and `lifetime` are stripped. A paused
`Process` may still keep the live runtime context internally so it can resume.
For ordinary algorithms the task result is the stripped context. For
`FinalizedAlgorithm`, the final function projects a result from that stripped
context, so `fetch(process)` still returns the `@finally` value.

Paused processes resume through the normal `loop` path with a `Resuming{true}`
entry trait. Fresh runs use `Resuming{false}`. This keeps the bootstrap decision
in dispatch, so fresh runs infer the post-bootstrap context type and resumed
runs infer the already-grown context type. New runtime inputs, init specs, and
lifetime changes are rejected while resuming.

## 6. Open Discovery Phase Need

Some future process algorithms may need type discovery after lifecycle `init`
has run and after routes are known, but before normal scheduled stepping begins.
This should not become public bootstrap API: the bootstrap/unsafe step remains
loop-owned, and transient values created only to discover route shapes should be
discarded after the run.

The intended future direction is a small route-aware discovery phase exposed
through the `@ProcessAlgorithm` API. That phase would let an algorithm declare
or compute first-step value shapes without requiring its scheduled `step!` to
run early. Until that exists, delayed algorithms that expose values to other
steps must initialize those values in persistent state or be wrapped in a
routine/composition whose first scheduled step makes the value available before
consumers run.
