# [Contexts and Indexing](@id contexts_user)

## What You Receive in `init`/`step!`/`cleanup`

The full runtime data object is a `ProcessContext`.

Each registered algorithm or state owns one named part of that context. That
part is a `SubContext`.

Entity methods receive a `SubContextView`, not the raw `ProcessContext`. A view
shows the values that the current entity is allowed to read. Those values can
come from its own subcontext, from a `Route`, from a `Share`, or from temporary
values supplied by the package.

That view exposes:

- local subcontext variables,
- routed/shared variables,
- globals via `getglobals(context)`.

## Reading Variables

```julia
function StatefulAlgorithms.step!(::MyAlgo, context)
    (; state, dt) = context
    # ...
    return (;)
end
```

`context.name` and destructuring both read from the view.

## Writing Variables

Return a `NamedTuple` from `step!`/`init`/`cleanup`.

- Existing names update mapped targets.
- New names are added to local subcontext.
- Type changes are rejected once the stable loop is running.

If `Target` sees `source_value` through a route and returns
`(; source_value = 2.0)`, the stored value in the source subcontext is updated.
If it returns `(; new_local_value = 2.0)`, that value is added to `Target`'s own
subcontext.

## Top-Level Context Access

From a process:

```julia
ctx = context(p)
```

`context(p)` returns the stored persistent context. `getcontext(p)` returns a
runtime-flavored context with the process injected into globals.

From a context, index by:

- symbol key: `ctx[:Fib_1]`
- registered value/type: `ctx[Fib]`, `ctx[Fib()]`, `ctx[my_unique_fib]`

Object and type lookup use the same identity rules as `Input`, `Override`,
`Route`, and `Share`. See [Referencing Algorithms](@ref referencing_algorithms_user).

Related symbol-based lookup also works on resolved loop algorithms and registries:

```julia
resolved = resolve(CompositeAlgorithm(Fib, Noise, (1, 2)))
reg = getregistry(resolved)

resolved[:Fib_1]   # same object as resolved.Fib_1
reg[:Fib_1]        # registered IdentifiableAlgo
ctx[:Fib_1]        # subcontext
```

Use loop-algorithm indexing when you want the registered algorithm or state
object, and context indexing when you want its current stored data.

## Re-Initializing One Subcontext

You can re-run `init` for one registered algorithm inside an existing context:

```julia
ctx = initcontext(resolved)

ctx = initcontext(ctx, :Fib_1)
ctx = initcontext(ctx, :Fib_1; inputs = (; seed = 123))
ctx = initcontext(ctx, resolved[:Fib_1]; overrides = (; value = 0.0))
```

This updates only the targeted subcontext.

- `inputs` are merged into that subcontext before `init(...)` runs.
- `overrides` are merged into that subcontext after `init(...)` returns.

## Globals

`ProcessContext` includes a `globals` field.

Common globals:

- `lifetime`
- `algo`
- `process` (in runtime loop context)

Use `getglobals(context)` inside entity methods when you need them. Globals are
process-level values, not values owned by one algorithm.

You can also select globals with `Var(:name)` in APIs like `Until(...)`.
See [Vars (`Var` Selectors)](@ref vars_user).

For buffered external writes through `ContextExchange` and ref-like
`view(context, Var(...))` handles, see [Interactive Contexts](@ref interactive_user).
