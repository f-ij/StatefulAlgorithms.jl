# [Process Pipeline Internals](@id process_pipeline_internals)

This page documents the runtime path from loop algorithm construction to loop
execution.

## 1. Construction

`Process(func, inputs_overrides...; repeats, lifetime, timeout)` (`src/Processes/Process/Constructors.jl`):

1. Turn `func` into a plan (`parse_plan`, `src/Processes/Construction.jl`): a plan or plan type as it is, anything
   else wrapped as a one-child `CompositeAlgorithm`.
2. Resolve the plan (its registry gets the plan's `UniqueKeyMap`), then make the lifetime (`parse_lifetime`):
   `repeats = n` becomes `Repeat(n)` (`repeats = Inf` becomes `Indefinite()`), `lifetime` takes a `Lifetime`, at most
   one of the two; with neither, `default_lifetime` gives `Repeat(1)` for a `Routine` and `Indefinite()` otherwise. A
   given lifetime's `Var`s get the plan's numbers for its `Unique` handles (`number_by_keymap_dynamic`).
3. Set up the context without the map (`_setup`: `init` compiles once for every set of `Unique` handles) and give it the
   plan's registry back (`with_keymap`), or take the given `context`.
4. Store the resolved plan (with the map), the context (`Process.state_context`) and the specs (`Process.specs`) on the
   process. `Process.runtime_context` holds a paused run's runtime context.
5. Register the process in `processlist` under its `list_ref`, compile its first run (`precompile_interface`,
   `src/PrecompileInterface.jl`) and set the finalizer `remove_process!`, which only drops the list entry (no `close`).

Construction goes `Process(...)` -> `_build_process` -> `_prepare_process` (the
plan, its context and the lifetime) -> `_construct_process` (the process and its
`InteractiveSession`); `InlineProcess` has the same three steps.

There is no `TaskData` layer. A resolved `LoopAlgorithm` holds no data: the process keeps its state context
(`getcontext(p)` reads `state_context`), the specs its context is set up from (`getspecs(p)`: resolved, merged with later `init!` calls, read by a full
`init!(p)`), a
paused run's runtime context, and its session (`InteractiveSession`), which keeps the counters, times, flags and the
loop cursor across pause/resume.

## 2. Init Phase

`setup(plan_spec, specs...)` (`src/LoopAlgorithms/DirectRuns.jl`, building the context in `_init_context_for`) applies:

1. Resolve `InitArgs`/`Override` specs through the registry.
2. Merge specs for the same target, later ones winning.
3. Build a fresh persistent `ProcessContext` from the resolved registry.
4. Merge `InitArgs` values into target subcontexts.
5. Build a separate init-only runtime context carrying `algo` and `lifetime`.
6. Run registered `init` hooks with persistent and runtime contexts kept
   separate.
7. Merge `Override` values after init, then apply `Interactive` wrappers.
8. Materialize the `Redirect` options collected from the plan tree into target context fields.
9. Return the context and the resolved plan.

For loop algorithms, `init(::LoopAlgorithm, ::InitContext)` iterates all registry entities in order (`src/LoopAlgorithms/Init.jl`).

`init(plan, context, specs...)` (`src/LoopAlgorithms/DirectRuns.jl`) uses the same target resolution on a given
context; with `Only(...)` it only rebuilds the subcontexts `Only` names.

## 3. Running

`run(p; kwargs...)` (`src/Processes/Process/Lifecycle.jl`) calls `_start_run!` (`src/Processes/Process/Loop.jl`),
with `resume = true` when `p` is paused. `_start_run!`:

- takes the state context (`getcontext(p)`),
- calls `prepare_for_loop(p, context, inputs, resume)`, the first call
  of every run (Processes/Hooks.jl): the session the run runs in, the plan
  without its `UniqueKeyMap` (`strip_keymap`) and the `LoopContext` the run starts from: `LoopContext(plan, context)`
  (the state context without its registry, `drop_registry`, and the plan's declared locals), then `with_inputs`, which
  checks the inputs against the plan's `@input` metadata and adds them, and
- spawns the loop task, which runs `_run_loop_and_store!`:
  `run_session_loop(loopfunc, session, plan, loop_context, lifetime, resume)`, then `_store_run_contexts!`.

`InlineProcess`, the manager's inline run and `run(plan, context)` start from
`prepare_for_loop` too.

The entered `loop` method then builds or restores the per-run
`AbstractLoopCursor` from the resolved plan.

`run(plan, context; kwargs...)` runs a resolved plan directly on a user-held context
with a fresh non-pausable loop cursor and returns the context you passed with the run's state values in it (it keeps
its registry, so `context[handle]` still works) and the run's result.

## 4. Loop Bootstrap and Runtime Inputs

The loop wrappers in `src/Loops.jl` get the run's `LoopContext`, its persistent
and its runtime context, as an argument, and the session instead of the process:

```julia
loop(session, algo, loop_context, lifetime, resume)
```

The loop's context has no registry, so everything that reads a `Var` gets the `Var`'s context key before the loop: the
run's lifetime at the loop's start (`resolve_var_keys(lifetime, getregistry(plan))`; an `InlineProcess` gives its own
lifetime its keys when it is built), and every `Var` in a schedule (a `RunIf`'s, a routine child's lifetime) when the
plan is resolved (`resolve` step 5, `_resolve_schedule_vars`).

The runtime context starts with the run's inputs (`:_inputs`, when there are
any) and declared locals (`:_declared_locals`). A step adds a return
(`:_captured_returns`, or the owner's entry in `:_subcontext_returns`) where it is
assigned, and the return is removed when its plan node ends, so every step gets
and returns a runtime context of the same type. The process and the lifetime are
not in it. None of these fields are added to the persistent context.

Repeat and indefinite loops are defined in `src/Loops.jl`. The generated loop mode is legacy and not loaded
(`src/Legacy/GeneratedLoops.jl`); `sys_looptype` is `NonGenerated()`.

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
   (`_store_run_contexts!`): the persistent context's values go into its state context
   (`_sync_state_context!`), the runtime context (inputs and declared locals) into
   `Process.runtime_context`; the session keeps the loop cursor. A resume combines
   the two again into one `LoopContext` and clears the slot; closing the paused
   process runs cleanup and final projection on the same combination.
2. Natural completion or `close` runs cleanup while the runtime context is still
   visible. Mapped cleanup writes update persistent state; cleanup-only outputs
   remain available to final projection.
3. A finished `Process` or `InlineProcess` stores only the cleaned persistent
   context. Direct `run(plan, context)` likewise returns only
   that persistent state (with the run's result).
4. The task result for an ordinary process is a temporary final-visible context:
   cleaned persistent state plus the runtime subcontexts still present at the end
   (inputs and declared locals; returns have ended with their blocks).
   `FinalizedAlgorithm` instead passes that projection to its final function and
   returns the function's result. The finalizer's context has the plan's registry
   (`with_registry`), so it can read `ctx[A]`; the result `fetch(p)` gives has the
   process's registry with the map (`with_plan_registry`).

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
