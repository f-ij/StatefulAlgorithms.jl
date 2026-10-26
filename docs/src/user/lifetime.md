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
- a plan built with `Routine(...)` / `@Routine` defaults to one pass (`Repeat(1)`): `Routine` adds the plan option
  `DefaultLifetime(Repeat(1))`, which any plan can be given

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

`CompositeAlgorithm(...)` and `Routine(...)` build the same kind of plan (`Plan`): each child has a schedule entry,
either an interval (`Interval(n)`, `RunIf`: at most once per step of the plan) or a lifetime (`Repeat(n)`, `Until`,
...: that many repeats in every step of the plan). The two constructors only differ in what a plain number means
(`CompositeAlgorithm`: an interval, `Routine`: a repeat) and in the default lifetime above, so entries can be mixed:

```julia
plan = CompositeAlgorithm(Measure, Sweep, (10, Repeat(100)))   # Measure every 10th step, Sweep 100 times every step
```

A `Process` is checked for a pause or close after every repeat. A pause in the middle of a step is resumed there by
the next `run(p)`: the repeats left and the children after them run, the children before do not run again, and the
returns they captured (`y = Algo()`) are still there.

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
