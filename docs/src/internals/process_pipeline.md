# [Process Pipeline Internals](@id process_pipeline_internals)

This page documents the runtime path from loop algorithm construction to loop
execution.

## 1. Construction

`Process(func, inputs_overrides...; repeats, lifetime, timeout)` (`src/Process.jl`):

1. Wrap a bare `StepAlgorithm` as a one-child `CompositeAlgorithm` plan.
2. Normalize stop behavior: `repeats = n` becomes `Repeat(n)`, `lifetime` accepts `Lifetime` objects, and `Routine` defaults to `Repeat(1)` when no lifetime is provided.
3. Resolve the plan into a `LoopAlgorithm` wrapper when needed.
4. Run lifecycle `init(algo, specs...; lifetime)` unless an initialized context is already provided.
5. Store the initialized algorithm wrapper on the process. Its typed lifecycle
   context is the normal persistent state; `Process.runtime_context` is reserved
   for a live/paused or shape-divergent context.

There is no `TaskData` layer. The initialized `LoopAlgorithm` carries the
persistent context plus stored init/override specs. A `Process` normally reads
its current persistent context from that wrapper. Its separate
`runtime_context` slot is used only for paused or shape-divergent state, and its
loop-cursor slot preserves scheduler position across pause/resume.

## 2. Init Phase

`init(la::LoopAlgorithm, specs...)` (`src/LoopAlgorithms/RuntimeInputs.jl`) applies:

1. Resolve `Init`/`Override` specs through the registry.
2. Merge passed specs over stored specs per target.
3. Build a fresh persistent `ProcessContext` from the resolved registry.
4. Merge `Init` values into target subcontexts.
5. Build a separate init-only runtime context carrying `algo` and `lifetime`.
6. Run registered `init` hooks with persistent and runtime contexts kept
   separate.
7. Merge `Override` values after init, then apply `Interactive` wrappers.
8. Materialize root-level `Replace` options into target context fields.
9. Return a loop algorithm with the persistent context and replayable lifecycle
   specs stored on it.

For loop algorithms, `init(::LoopAlgorithm, ::ProcessContext)` iterates all registry entities in order (`src/LoopAlgorithms/Init.jl`).

`partialinit(la, specs...)` uses the same target resolution but only rebuilds
the targeted subcontexts.

## 3. Running

`run(p; kwargs...)` (`src/ProcessInteraction.jl`) calls `makeloop!` (`src/Process.jl`).

`makeloop!`:

- validates runtime keyword arguments against the loop algorithm's `@input` metadata,
- selects the current persistent or paused context,
- passes that context and the runtime-input `NamedTuple` to `loop`, and
- spawns the loop task.

The entered `loop` method then builds or restores the per-run
`AbstractLoopCursor` from the resolved plan.

`run(la::LoopAlgorithm; kwargs...)` runs an initialized loop algorithm directly
with a fresh non-pausable loop cursor and returns a loop algorithm with the next
persistent context.

## 4. Loop Bootstrap and Runtime Inputs

The loop wrappers in `src/Loops.jl` build a separate runtime context before the
while/for loop:

```julia
loop(process, algo, context, lifetime, inputs)
```

The loop puts `process` and `lifetime` in the runtime context's `:_runtime`
subcontext. A non-empty validated input tuple is stored in its `:_input`
subcontext. Demanded transient child returns are stored in owner-named runtime
subcontexts. None of these fields are added to the persistent context.

Repeat and indefinite loops are defined in `src/Loops.jl`; generated loops live
in `src/GeneratedCode/GeneratedLoops.jl`.

High-level structure:

1. `before_while(process)`
2. build or restore the per-run loop cursor and runtime context
3. execute one initial scheduled step for a fresh run
4. execute the remaining repeat/while body with tick/index increments
5. either store paused state or run cleanup/final-result projection

Composite and routine steps receive an explicit loop cursor. Composite cursors
own the interval counter for that run. Pausable process runs allocate routine
resume storage; direct runs use non-pausable cursors without a mutable resume
array.

## 5. Cleanup Behavior

The completion paths distinguish stored state from the task result:

1. Pausing skips cleanup, stores the persistent state plus runtime inputs needed
   for resume, and keeps the loop cursor. Closing that paused process later runs
   cleanup and final projection.
2. Natural completion or `close` runs cleanup while the runtime context is still
   visible. Mapped cleanup writes update persistent state; cleanup-only outputs
   remain available to final projection.
3. A finished `Process` or `InlineProcess` stores only the cleaned persistent
   context. Direct `run(la)` likewise returns a loop algorithm containing only
   that persistent state.
4. The task result for an ordinary process is a temporary final-visible context:
   cleaned persistent state plus runtime subcontexts still present at the end.
   `FinalizedAlgorithm` instead passes that projection to its final function and
   returns the function's result.

Paused processes resume through the normal `loop` path with a `Resuming{true}`
entry trait; fresh runs use `Resuming{false}`. New runtime inputs, init specs, and
lifetime changes are rejected while resuming.

## 6. Scheduling and Transient Dataflow

There is no pre-run shape-discovery phase. A new `step!` return exists only in
the runtime context after its producer has actually run, and only when wiring or
the root finalizer demands it. Consequently, a consumer of a delayed transient
output must not run before that producer. Align their plan schedules, order them
inside a routine, or initialize a persistent field through an entity's lifecycle
when a value must exist earlier.
