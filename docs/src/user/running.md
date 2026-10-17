# [Running, Wait, Fetch](@id running_user)

This page covers the normal runtime flow: create a `Process`, run it, wait for it, and inspect the result.

## Create a Process

```julia
p = Process(algo, Init(...), Override(...); repeats = 1_000)
```

`Process(...)` resolves the loop algorithm when needed, runs the lifecycle
`init` path, and stores the algorithm plus its current context on the process.

Persistent context is built from `Init(...)`, `Override(...)`, `@state`, routes,
shares, and managed state. Runtime `@input` values are not stored at
construction time.

## Run and Resume

```julia
run(p)
```

`run(p)` starts the process loop task. If the process was paused, `run(p)`
resumes the suspended runtime context and loop cursor; new runtime inputs, init
specs, and lifetime changes are rejected during resume.

If the loop algorithm declares runtime `@input` values, pass them as run
keywords:

```julia
run(p; temperature = 2.0, sweep = 10)
```

The keywords are converted to a `NamedTuple`, validated against the algorithm's
runtime input declarations, and become the run's inputs (`_inputs`, read-only) only for
that loop run. Finished processes strip runtime-only fields before storing their
persistent context. A paused process may keep its live runtime context and loop
cursor internally so it can resume.

Initialized loop algorithms can also be run directly:

```julia
la = init(resolve(algo), Init(MyAlgo; buffer = Float64[]))
la = run(la; temperature = 2.0)
```

The returned loop algorithm contains the next persistent context. Use the
returned value; runtime inputs are stripped before the context is stored back
on the returned algorithm.

## Lifetime

Stop behavior can be given either as a simple repeat count or as a lifetime
object:

- `repeats = 1000` -> run a fixed number of iterations.
- omitted -> default lifetime behavior for that algorithm type.
- advanced: `lifetime = Repeat(...)`, `lifetime = Indefinite()`, `lifetime = Until(...)`, `lifetime = RepeatOrUntil(...)`.

See [Lifetime](@ref lifetime_user) for full details.
For selector syntax used in `Until`, see [Vars (`Var` Selectors)](@ref vars_user).

## Control Operations

- `pause(p)`: stop loop while keeping resumable state.
- `run(p)`: start a new task or resume after pause.
- `close(p)`: stop the process, wait for it, run cleanup when needed, and commit
  the final persistent context.
- `reinit(p)`: compatibility helper that pauses, reruns lifecycle `init`, and runs again.
- `partialinit(la, specs...)`: rebuild only the targeted algorithms or states on an initialized loop algorithm.

## Waiting and Fetching

- `wait(p)`: block until task completes.
- `fetch(p)`: return the task return value.

In practice:

- use `wait(p)` when you just want to block until completion,
- use `fetch(p)` when you want the task's return value,
- use either `context(p)` or `getcontext(p)` for the current stored process
  context; `getcontext(p, key)` additionally indexes it by `key`.

For an ordinary process, the task result is the final context: the cleaned
persistent context with the runtime values still there at the end of the run, the
inputs (`_inputs`) and the declared locals (`_declared_locals`). Returns are not
in it: a block's returns end with the block. A root finalizer gets this context,
so `@finally ctx -> ctx.result` hands a `local result` out of the run.
The process itself stores only the cleaned persistent context, so use
`context(p)` when you need the state that will be reused by a later run. A
`FinalizedAlgorithm` can instead make `fetch(p)` return the finalizer function's
result.

## Status Helpers

- `isrunning(p)`
- `ispaused(p)`
- `isdone(p)`
- `isidle(p)`

## Inline Process

Use `InlineProcess` when you want synchronous execution without a separate process task.
It accepts the same positional `Init(...)`/`Input(...)` and `Override(...)`
arguments as `Process(...)`:

```julia
ip = InlineProcess(algo, Init(...), Override(...); repeats = 10_000)
run(ip)
```

`InlineProcess` also accepts `lifetime = 10_000` and converts it to a repeat
count. For `Process`, use `repeats = 10_000` or `lifetime = Repeat(10_000)`.
Unlike `Process`, `InlineProcess` stores a context that can be absorbed back
into an algorithm, so the run's runtime values (inputs and declared locals) are
stripped after the loop. `run(ip)` returns the same final context as `fetch(p)`
does for a `Process` (or the finalizer's result).
Like finished `Process` runs, this means the persistent context is the persistent
context shape rather than the transient loop context.

If you need buffered external updates to context variables, see
[Interactive Contexts](@ref interactive_user).
