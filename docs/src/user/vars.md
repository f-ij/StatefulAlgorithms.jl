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

Which subcontext that is, is decided as for a route endpoint:

| # | `entity_ref` | Reads from |
|---|---|---|
| 1 | symbol key (`:Sensor_1`) | the subcontext with that key |
| 2 | saved instance or `Unique(...)` value | the subcontext of that algorithm or state |
| 3 | type (`Counter`) | the subcontext of the first registered algorithm of that type; use a key or an instance when there are several |

The reference is stored in the `Var`'s type (a key as itself, anything else as
the matcher the registry identifies it by), so a `Var` holds no values and the
lookup is resolved when the code is compiled.

Example:

```julia
counter = Counter()
Var(counter, :count)
```

### 2. Captured return

```julia
Var(:name)
```

This reads the captured return `name` (`_captured_returns`): the value a DSL
statement `name = f(...)` assigned in the current step. Captured returns are not
stored in the persistent context, so a process `lifetime` cannot read them; use
the subcontext form there.

## Common Use in `Until`

`Var` is commonly used with `Until(...)` to pick what value the stop condition should inspect.

Example with a subcontext variable:

```julia
counter = Counter()

lifetime = Until(x -> x >= 100, Var(counter, :count))
```

In `Until`/`RepeatOrUntil`, this function is a stop condition (`true => stop`, `false => continue`).

`ContextExchange` also accepts `Var` selectors when its exposed variables are
configured. After initialization, `view(context, Var(exchange_key, :name))`
selects the exchange and its external name; in that particular overload, the
first `Var` argument is the exchange key rather than the target entity. Prefer
the clearer `view(context, :name; exchange = exchange_key)` form in new code.
See [Interactive Contexts](@ref interactive_user).
