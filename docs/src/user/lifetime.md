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

For `Process`, the `lifetime` keyword is reserved for `Lifetime` objects. Use
`repeats = ...` for plain integer counts.

### Default behavior

If you do not pass `lifetime`:

- most processes default to `Indefinite()`
- `Routine` defaults to one pass (`Repeat(1)`) when `lifetime = nothing`

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

For an existing process, build a fresh process from the same task description
with a different lifetime:

```julia
p2 = copyprocess(p; lifetime = Repeat(2_000))
```

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
- `Var(:name)` reads from globals (for example `Var(:process)`).
- The safest current `Until` usage is a single selector value.

For full `Var` details, see [Vars (`Var` Selectors)](@ref vars_user).

## Notes

- The lifetime types are exported, so `Repeat(10)` and `StatefulAlgorithms.Repeat(10)` both work after `using StatefulAlgorithms`.
- Manual stop and pause still work regardless of lifetime.
