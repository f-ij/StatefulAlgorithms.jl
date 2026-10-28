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
   context is the normal persistent state; `Process.paused_context` holds a paused run's context (kept by the run's
   end, read by a resumed run and by `close`), `Process.reshaped_context` a committed context of another type than the
   plan's.

There is no `TaskData` layer. The initialized `LoopAlgorithm` carries the
persistent context plus stored init/override specs. A `Process` normally reads
its current persistent context from that wrapper; `paused_context` and `reshaped_context` are used only for paused or
shape-divergent state. `makeloop!` reads the lifetime and the context from fields of abstract type and calls
`_makeloop!`, dispatched on their types at run time. The run itself (counters, times, the
pause and stop flags, the loop cursor that preserves scheduler position across pause/resume) is the process's
session (`getsession(p)`, an `InteractiveSession`; `src/Sessions/`), which the loop gets instead of the process.

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

- validates runtime keyword arguments against the loop algorithm's `@input` metadata,
- selects the current persistent or paused context,
- picks the run's session (`create_session`),
- spawns the loop task, which passes the session, the plan, that context and the runtime-input `NamedTuple` to the
  loop (`run_session_loop`) and then ends the run on the process (`_finish_run!`: commits the context, or keeps it
  and the cursor on a pause).

The entered `loop` method then builds or restores the per-run
`AbstractLoopCursor` from the resolved plan.

`run(la::LoopAlgorithm; kwargs...)` runs an initialized loop algorithm directly
with a fresh non-pausable loop cursor and returns a loop algorithm with the next
persistent context.

## 4. Loop Bootstrap and Runtime Inputs

The loop wrappers in `src/Loops.jl` build a separate runtime context before the
while/for loop:

```julia
loop(session, algo, context, lifetime, inputs, resume)
```

The runtime context starts with the run's inputs (`:_inputs`, when there are
any) and declared locals (`:_declared_locals`). A step adds a return
(`:_captured_returns`, or the owner's entry in `:_subcontext_returns`) where it is
assigned, and the return is removed when its plan node ends, so every step gets
and returns a runtime context of the same type. The session and the lifetime are
not in it. None of these fields are added to the persistent context.

Repeat and indefinite loops are defined in `src/Loops.jl`; generated loops live
in `src/Legacy/GeneratedLoops.jl`.

High-level structure:

1. `before_while(session)`
2. build or restore the per-run loop cursor and runtime context
3. execute the repeat/while body with tick/index increments
4. either keep the cursor (pause) or run cleanup/final-result projection, and return `(persistent_context, result)`;
   the process commits them (`Process`: `_finish_run!`; `InlineProcess`: `run_session_loop!` keeps the context on the
   process's session; `run(ip; inlined = Val(true))` pastes its body, `run_session_loop_body!`, into `run(ip)`)

Composite and routine steps receive an explicit loop cursor. Composite cursors
own the interval counter for that run. Pausable process runs allocate routine
resume storage; direct runs use non-pausable cursors without a mutable resume
array.

## 5. Cleanup Behavior

The completion paths distinguish stored state from the task result:

1. Pausing skips cleanup, stores the persistent state plus the runtime inputs and
   declared locals needed for resume, and keeps the loop cursor. Closing that paused process later runs
   cleanup and final projection.
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
