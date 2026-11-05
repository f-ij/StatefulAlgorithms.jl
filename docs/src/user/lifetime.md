# [Lifetime](@id lifetime_user)

`lifetime` controls when a process loop stops.

## Most Common Usage

### Fixed number of iterations

```julia
p = Process(algo; repeats = 1_000)
```

The `repeats` keyword is converted internally to `Repeat(1000)`.

You can also pass the lifetime object explicitly:

```julia
p = Process(algo; lifetime = Repeat(1_000))
```

The `lifetime` keyword takes only `Lifetime` objects (for every process type and for
`run`); a number there is an error. Use `repeats = ...` for plain integer counts, or
`repeats = Inf` for `Indefinite()`.

### Default behavior

If you do not pass `lifetime`:

- a `Process` or `TimedProcess` defaults to `Indefinite()`, except for a `Routine`,
  which defaults to one pass (`Repeat(1)`)
- an `InlineProcess` defaults to one pass (`Repeat(1)`)

## Explicit Lifetime Types

These types are available in code:

- `Repeat(n)`
- `Indefinite()`
- `Until(condition, selector)`
- `RepeatOrUntil(condition, n, selector)`

The exported `AtLeast` and `AtLeastAtMost` lifetime types are also available for
less common "minimum count plus condition" rules.

## Changing Lifetime

Set the process lifetime when constructing the process:

```julia
p = Process(algo; lifetime = Repeat(1_000))
```

`getlifetime(p)` returns it. `run(p)` takes no `repeats` or `lifetime`: a
`Process` or `TimedProcess` runs with its own lifetime. Change it between runs:

```julia
setlifetime!(p, Repeat(2_000))      # Process, TimedProcess: not while running or paused
p2 = setlifetime(p, Repeat(2_000))  # a new process with the same plan, specs and context object
```

An `InlineProcess` has the lifetime's type as a type parameter, so it has only
`setlifetime(ip, lt)`, which returns a new `InlineProcess`. A single run of an
`InlineProcess` can use another lifetime without changing the stored one:
`run(ip; repeats = 10)`. `run(plan, context; repeats/lifetime)` takes a lifetime
for that run as well.

This changes the outer process lifetime. It does not change how often child
loop algorithms run inside a `CompositeAlgorithm` or `Routine`. Those schedules
are loop-algorithm settings: use `changeinterval`, `changeintervals`, or the
schedule argument to `addalgo`. See
[Algorithms and States](@ref algorithms_states_user).

## `Until`: Stop on a Condition

`Until` checks a value from context each loop.  
Here, `condition(value)` is a **stop condition**:

- `true` -> stop now
- `false` -> continue

A practical pattern is to use `Var(...)` as selector:

```julia
counter = Counter()

p = Process(
    counter;
    lifetime = Until(
        x -> x >= 100,
        Var(counter, :count),
    ),
)
```

## `RepeatOrUntil`: Max Iterations Or Condition

`RepeatOrUntil` combines:

- a maximum number of iterations (`n`)
- a stop condition like `Until`

The loop stops at whichever happens first:

1. repeat count reaches `n`, or
2. condition becomes `true`.

Example:

```julia
counter = Counter()

p = Process(
    counter;
    lifetime = RepeatOrUntil(
        x -> x >= 100,   # stop condition
        1_000,           # hard max iterations
        Var(counter, :count),
    ),
)
```

Important:

- Use the same algorithm reference you used in `Process(...)` (same instance or same `Unique` variable).
- `Var(:name)` reads a captured return, which is not stored in the persistent context; a process `lifetime` selects a stored field with `Var(entity_ref, :name)`.
- The safest current `Until` usage is a single selector value.

For full `Var` details, see [Vars (`Var` Selectors)](@ref vars_user).

## Notes

- The lifetime types are exported, so `Repeat(10)` and `StatefulAlgorithms.Repeat(10)` both work after `using StatefulAlgorithms`.
- Manual stop and pause still work regardless of lifetime.
