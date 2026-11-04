# [The Pipeline: Setup, Run, Cleanup](@id pipeline_user)

Every plan goes through the same three steps:

| Step | Call | What it does | Returns |
|---|---|---|---|
| 1 | `setup(plan_spec, Init(...), Override(...))` | resolves the plan and builds its starting context | `(context, plan)` |
| 2 | `run(plan, context; inputs...)` | runs the plan on the context | `(context, result)` |
| 3 | `cleanup(plan, context)` | ends the context's life | the cleaned context |

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

context, plan = setup(plan_spec, Init(Counter; total = 10))   # total == 10
context, _ = run(plan, context; repeats = 3, step = 2)        # total == 16
context, _ = run(plan, context; repeats = 1, step = 4)        # total == 20
context = cleanup(plan, context)
```

### `setup`

- `Init(Target; values...)` says which values go to which algorithm. Its `init` sees them.
- `Override(Target; values...)` sets values after `init` has run.
- `lifetime = ...` (optional) tells `init` how long the run will be, so it can size buffers.

The returned plan holds no context. The context is yours.

### `run`

- `repeats = n` or `lifetime = ...` sets how long the run lasts.
- The other keywords are the plan's `@input` values for this run.
- It returns the final context and the run's result, which is what the plan's finalizer returns.
- Values that exist only during a run (inputs, locals, returns) are dropped at the end; only the state comes back.

### `cleanup`

Call `cleanup` once, when you are done with the context. Not after every run: the context should stay usable for the
next `run`.

!!! note
    Today `run` also runs each algorithm's `cleanup` at the end of every run. This will change: cleanup will be
    called only by you, at the end of the context's life.

## With a process

A `Process` does `setup` for you and keeps the context:

```julia
p = Process(plan_spec, Init(Counter; total = 10); repeats = 3)
run(p; step = 2)
wait(p)
getcontext(p)
close(p)
```

See [Running, Wait, Fetch](@ref running_user) for running, pausing and closing a process.
