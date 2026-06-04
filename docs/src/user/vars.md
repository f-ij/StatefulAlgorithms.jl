# [Vars (`Var` Selectors)](@id vars_user)

`Var` is a small selector object used to say "read this stored value later".

It is most often used by lifetimes such as `Until`, where the stop condition
needs one value from the current context.

## Two Forms

### 1. Subcontext variable

```julia
Var(entity_ref, :name)
```

This reads `:name` from the subcontext of `entity_ref`. Use the same
`entity_ref` style you used when building the process: type, saved instance,
saved `Unique(...)` value, or symbol key.

Example:

```julia
counter = Counter()
Var(counter, :count)
```

### 2. Global variable

```julia
Var(:name)
```

This reads `:name` from `context.globals`.

So:

- `Var(:process)` reads `context.globals.process`
- `Var(:algo)` reads `context.globals.algo`
- `Var(:lifetime)` reads `context.globals.lifetime`

## Common Use in `Until`

`Var` is commonly used with `Until(...)` to pick what value the stop condition should inspect.

Example with a subcontext variable:

```julia
counter = Counter()

lifetime = Until(x -> x >= 100, Var(counter, :count))
```

Example with a global variable (process object):

```julia
lifetime = Until(p -> loopidx(p) >= 10_000, Var(:process))
```

`Var(:process)` is useful when your stop rule depends on process-level state.

In `Until`/`RepeatOrUntil`, this function is a stop condition (`true => stop`, `false => continue`).

`Var(...)` is also the selector syntax used by interactive refs returned from
`view(context, Var(...))`. See [Interactive Contexts](@ref interactive_user).
