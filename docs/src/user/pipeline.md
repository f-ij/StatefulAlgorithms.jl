# [The Pipeline: Setup, Run, Cleanup](@id pipeline_user)

Every plan goes through the same three steps:

| Step | Call | What it does | Returns |
|---|---|---|---|
| 1 | `setup(plan_spec, InitArgs(...), Override(...))` | resolves the plan and builds its starting context | `(context, plan)` |
| 2 | `run(plan, context; inputs...)` | runs the plan on the context | `(context, result)` |
| 3 | `cleanup(plan, context)` | ends the context's life | the cleaned context |

Between runs, `init(plan, context, InitArgs(...), Override(...))` runs every `init` again on the context, and
`init(plan, context, Only(A, B), ...)` runs only A's and B's and keeps the rest of the context.

`plan_spec` is what you define with `@StepAlgorithm`, `@CompositeAlgorithm` or `@Routine`. `plan` is the resolved
version that `setup` returns. Pass that one to `run` and `cleanup`, not the spec.

## Without a process

You hold the context yourself and pass it from call to call:

```julia
@StepAlgorithm function Counter(step, @managed(total = total); @init((; total = 0)))
    @update total += step
end

plan_spec = @CompositeAlgorithm begin
    @input step
    Counter(step)
end

context, plan = setup(plan_spec, InitArgs(Counter; total = 10))   # total == 10
context, _ = run(plan, context; repeats = 3, step = 2)        # total == 16
context, _ = run(plan, context; repeats = 1, step = 4)        # total == 20
context = cleanup(plan, context)
```

### `setup`

- Every algorithm's `init` runs.
- `InitArgs(Target; values...)` gives the values that algorithm's `init` reads. For several targets at once:
  `InitArgs(A => (; x = 1, y = 2), B => (; z = 3))`. `InitArgs(; values...)` gives them to every algorithm.
- `Override(Target; values...)` sets values after `init` has run.
- `lifetime = ...` (optional) tells `init` how long the run will be, so it can size buffers.

The returned plan holds no context. The context is yours.

### `run`

- `repeats = n` or `lifetime = ...` sets how long the run lasts.
- The other keywords are the plan's `@input` values for this run.
- It returns the final context and the run's result, which is what the plan's finalizer returns.
- Values that exist only during a run (inputs, locals, returns) are dropped at the end; only the state comes back.

### `init`

```julia
context = init(plan, context, InitArgs(Counter; total = 0))                 # every init runs
context = init(plan, context, Only(Counter), InitArgs(Counter; total = 0))   # only Counter's init runs
```

- Without `Only`, every algorithm's `init` runs on the context you pass. To start from an empty context, use `setup`.
- With `Only(A, B)`, only A's and B's `init` run; the other algorithms keep their values. At most one `Only` per call.
- Each `init` reads its part of the context with the `InitArgs` values merged in. `InitArgs` for a target that `Only`
  leaves out is an error.
- An `Override` is set after its target's `init`. An `Override` for a target whose `init` does not run only sets its
  values.

### `cleanup`

Call `cleanup` once, when you are done with the context. Not after every run: the context should stay usable for the
next `run`.

!!! note
    Today `run` also runs each algorithm's `cleanup` at the end of every run. This will change: cleanup will be
    called only by you, at the end of the context's life.

## With a process

A `Process` does `setup` for you and keeps the context:

```julia
p = Process(plan_spec, InitArgs(Counter; total = 10); repeats = 3)
run(p; step = 2)
wait(p)
getcontext(p)
close(p)
```

See [Running, Wait, Fetch](@ref running_user) for running, pausing and closing a process.
