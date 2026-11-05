# [Running, Wait, Fetch](@id running_user)

This page covers the normal runtime flow: create a `Process`, run it, wait for it, and inspect the result.

## Create a Process

```julia
p = Process(algo, InitArgs(...), Override(...); repeats = 1_000)
```

`Process(...)` runs `setup` (it resolves the plan and runs every `init`) and keeps the
resolved plan, the context and the specs on the process. `Process(algo; context = ctx)`
starts from a context you built instead; passing both `context` and specs is an error.

Persistent context is built from `InitArgs(...)`, `Override(...)`, `@state`, routes,
shares, and managed state. Runtime `@input` values are not stored at
construction time.

## Run and Resume

```julia
run(p)
```

`run(p)` starts the process loop task. If the process was paused, `run(p)`
resumes the suspended runtime context and loop cursor, with the lifetime the run
started with; new runtime inputs, init specs, `repeats` and `lifetime` are rejected
during resume.

If the loop algorithm declares runtime `@input` values, pass them as run
keywords:

```julia
run(p; temperature = 2.0, sweep = 10)
```

The keywords are converted to a `NamedTuple`, validated against the algorithm's
runtime input declarations, and become the run's inputs (`_inputs`, read-only) only for
that loop run. Finished processes strip runtime-only fields before storing their
persistent context. A paused process keeps the run's runtime context (its inputs and
declared locals) and loop cursor internally, apart from its context, so it can resume;
`getcontext(p)` is the process's state context, paused or not.

A plan can also be run without a process, with `setup`, `run` and `cleanup`
(see [The Pipeline: Setup, Run, Cleanup](@ref pipeline_user)):

```julia
context, plan = setup(algo, InitArgs(MyAlgo; buffer = Float64[]))
context, result = run(plan, context; temperature = 2.0)
```

## Lifetime

Stop behavior can be given either as a simple repeat count or as a lifetime
object:

- `repeats = 1000` -> run a fixed number of iterations.
- omitted -> one repeat for a `Routine`, otherwise until the process is closed
  (`Indefinite()`); an `InlineProcess` defaults to one repeat.
- advanced: `lifetime = Repeat(...)`, `lifetime = Indefinite()`, `lifetime = Until(...)`, `lifetime = RepeatOrUntil(...)`.

These go to the constructor. `run(p; repeats = 10)` (or `lifetime = ...`) uses
that lifetime for one run and leaves the process's own; change the process's
lifetime with `setlifetime!(p, lt)`.

See [Lifetime](@ref lifetime_user) for full details.
For selector syntax used in `Until`, see [Vars (`Var` Selectors)](@ref vars_user).

## Control Operations

- `pause(p)`: stop loop while keeping resumable state.
- `run(p)`: start a new task or resume after pause.
- `close(p)`: stop the process, wait for it, run cleanup when needed, and commit
  the final persistent context.
- `init!(p, InitArgs(...), Override(...))`: runs every `init` again, from the process's stored specs with the new
  ones merged over them, and makes the result the process's state. The process keeps the merged specs.
- `init!(p, Only(A, B), InitArgs(...))`: only A's and B's `init` run, on the current state; the rest is kept.
- A running process is paused for `init!` and runs on after; a paused one stays paused.
- An `InlineProcess` has `init(ip, ...)` instead, which returns a new process (see
  [Changing typed data: no `!`](@ref no_bang_rule)).

## Waiting and Fetching

- `wait(p)`: block until task completes.
- `fetch(p)`: return the task return value.

In practice:

- use `wait(p)` when you just want to block until completion,
- use `fetch(p)` when you want the task's return value,
- use `getcontext(p)` for the current stored process context, and `getcontext(p)[key]` to index it by `key`.

For an ordinary process, the task result is the final context: the cleaned
persistent context with the runtime values still there at the end of the run, the
inputs (`_inputs`) and the declared locals (`_declared_locals`). Returns are not
in it: a block's returns end with the block. A root finalizer gets this context,
so `@finally ctx -> ctx.result` hands a `local result` out of the run.
The process itself stores only the cleaned persistent context, so use
`getcontext(p)` when you need the state that will be reused by a later run. A
`FinalizedAlgorithm` can instead make `fetch(p)` return the finalizer function's
result.

## Status Helpers

- `isrunning(p)`
- `ispaused(p)`
- `isdone(p)`
- `isidle(p)`

## Inline Process

Use `InlineProcess` when you want synchronous execution without a separate process task.
It accepts the same positional `InitArgs(...)` and `Override(...)` arguments as
`Process(...)`:

```julia
ip = InlineProcess(algo, InitArgs(...), Override(...); repeats = 10_000)
run(ip)
```

Both process types take a repeat count as `repeats = 10_000` and a lifetime as
`lifetime = Repeat(10_000)`; a number given as `lifetime` is an error.
`run(ip)` runs the loop in the caller's task and returns the same final context as
`fetch(p)` does for a `Process` (or the finalizer's result). Like a finished `Process`
run, the process then stores only the persistent context: the run's runtime values
(inputs and declared locals) are dropped. An `InlineProcess` cannot be paused.
`run(ip; context = ctx)` makes `ctx` (of the process's context type) its context
before the run.

### [Changing typed data: no `!`](@id no_bang_rule)

An `InlineProcess` is fully typed: its context, specs and lifetime are type
parameters. A call that can change one of those types cannot change the process
in place, so it has no `!` and returns a new `InlineProcess`; the old one is left
as it was. The missing `!` tells you to keep the result:

```julia
ip = init(ip, InitArgs(A; x = 5))           # init again, from ip's specs with these merged over them
ip = init(ip, Only(A), InitArgs(A; x = 5))  # only A's init, on ip's current context
ip = reset(ip)                              # a fresh context from ip's specs
ip = setlifetime(ip, Repeat(2_000))
```

Every `InlineProcess` call that changes the process works this way. The new
process keeps the merged specs, so a later `reset(ip)` or `init(ip)` starts
from `x = 5`. `init_and_run(ip, specs...)` is `run(init(ip, specs...))`.
A `Process` or `TimedProcess` has the `!` forms (`init!`, `setlifetime!`, and
`reset!` for a `Process`), which change the process and return it.

If you need buffered external updates to context variables, see
[Interactive Contexts](@ref interactive_user).
