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
   context is the normal state context; `Process.state_context` holds it instead
   when its type changed, and `Process.runtime_context` holds a paused run's
   runtime context.

Construction goes `Process(...)` -> `_build_process` -> `_prepare_process` (the
plan, its context and the lifetime) -> `_construct_process` (the process and its
`InteractiveSession`); `InlineProcess` has the same three steps.

There is no `TaskData` layer. The initialized `LoopAlgorithm` carries the
persistent context plus stored init/override specs. A `Process` normally reads
its current state context from that wrapper (`context(p)`). Its separate
`state_context` slot is used only for shape-divergent state, its `runtime_context`
slot only while a run is paused, and its session (`InteractiveSession`) keeps the
counters, times, flags and the loop cursor across pause/resume.

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
8. Materialize the `Redirect` options collected from the plan tree into target context fields.
9. Return a loop algorithm with the persistent context and replayable lifecycle
   specs stored on it.

For loop algorithms, `init(::LoopAlgorithm, ::ProcessContext)` iterates all registry entities in order (`src/LoopAlgorithms/Init.jl`).

`partialinit(la, specs...)` uses the same target resolution but only rebuilds
the targeted subcontexts.

## 3. Running

`run(p; kwargs...)` (`src/ProcessInteraction.jl`) calls `makeloop!` (`src/Process.jl`).

`makeloop!`:

- picks the state context (typed from the plan, or from `state_context`),
- calls `prepare_for_loop(p, context, inputs, lifetime, resume)`, the first call
  of every run (AbstractProcesses/Hooks.jl): the session the run runs in, the plan
  and the `LoopContext` the run starts from, made by
  `LoopContext(plan, context, inputs, resume)`, which validates the inputs against
  the plan's `@input` metadata, and
- spawns the loop task (`_start_run!`), which calls
  `run_session_loop(session, plan, loop_context, lifetime, resume)`.

`InlineProcess`, the manager's inline run and `run(plan)` start from
`prepare_for_loop` too.

The entered `loop` method then builds or restores the per-run
`AbstractLoopCursor` from the resolved plan.

`run(la::LoopAlgorithm; kwargs...)` runs an initialized loop algorithm directly
with a fresh non-pausable loop cursor and returns a loop algorithm with the next
persistent context.

## 4. Loop Bootstrap and Runtime Inputs

The loop wrappers in `src/Loops.jl` get the run's `LoopContext`, its persistent
and its runtime context, as an argument, and the session instead of the process:

```julia
loop(session, algo, loop_context, lifetime, resume)
```

The runtime context starts with the run's inputs (`:_inputs`, when there are
any) and declared locals (`:_declared_locals`). A step adds a return
(`:_captured_returns`, or the owner's entry in `:_subcontext_returns`) where it is
assigned, and the return is removed when its plan node ends, so every step gets
and returns a runtime context of the same type. The process and the lifetime are
not in it. None of these fields are added to the persistent context.

Repeat and indefinite loops are defined in `src/Loops.jl`; generated loops live
in `src/GeneratedCode/GeneratedLoops.jl`.

High-level structure:

1. `before_while(session)`
2. build or restore the per-run loop cursor
3. execute the repeat/while body with tick/index increments
4. either hand back the `LoopContext` on a pause or run cleanup/final-result projection

Composite and routine steps receive an explicit loop cursor. Composite cursors
own the interval counter for that run. Pausable process runs allocate routine
resume storage; direct runs use non-pausable cursors without a mutable resume
array.

## 5. Cleanup Behavior

The completion paths distinguish stored state from the task result:

1. Pausing skips cleanup. The process takes the run's `LoopContext` apart
   (`_finish_run!`): the persistent context's values go into its state context
   (`_sync_state_context!`), the runtime context (inputs and declared locals) into
   `Process.runtime_context`; the session keeps the loop cursor. A resume combines
   the two again into one `LoopContext` and clears the slot; closing the paused
   process runs cleanup and final projection on the same combination.
2. Natural completion or `close` runs cleanup while the runtime context is still
   visible. Mapped cleanup writes update persistent state; cleanup-only outputs
   remain available to final projection.
3. A finished `Process` or `InlineProcess` stores only the cleaned persistent
   context. Direct `run(la)` likewise returns a loop algorithm containing only
   that persistent state.
4. The task result for an ordinary process is a temporary final-visible context:
   cleaned persistent state plus the runtime subcontexts still present at the end
   (inputs and declared locals; returns have ended with their blocks).
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
