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

Return a `NamedTuple` from each lifecycle hook, but note that the phase changes
what that return means.

1. `init` defines the persistent fields owned by the entity and replaces its
   initially empty subcontext with those fields.
2. `step!` updates existing local, routed, or shared fields. A new name is a
   loop-local output: it remains available only when downstream routing or a
   root finalizer demands it, and it is not added to the persistent subcontext.
3. `cleanup` uses the same mapped-write mechanism as `step!`; its returned
   existing fields are committed during finalization.

Changing the type of an existing persistent field is rejected. If a value must
change without changing context shape, initialize a suitably typed `Ref` or
mutable buffer and update its contents.

If `Target` sees `source_value` through a route and returns
`(; source_value = 2.0)`, the stored value in the source subcontext is updated.
If a value must persist, create its field during `init`, with `@managed`, or
with `@state`, then return that existing name from `step!`.

## Top-Level Context Access

From a process:

```julia
ctx = context(p)
```

`context(p)` and `getcontext(p)` both return the process's current stored
context. `getcontext(p, key)` is shorthand for indexing that context by `key`.
The running loop injects `process` only into the transient runtime context seen
by lifecycle hooks; it is not present in the stored context after completion.

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

## Runtime Globals

Persistent `ProcessContext` values do not have a dedicated `globals` field.
During lifecycle execution, the package passes a separate runtime context whose
`:_runtime` subcontext contains process-level values such as `lifetime`, `algo`,
or `process`, depending on the phase. Entity views expose that transient bucket
through `getglobals(context)`.

Runtime globals are not owned by an algorithm and are not retained in the
finished process's persistent context. For selector syntax, see
[Vars (`Var` Selectors)](@ref vars_user).

For immediate `InteractiveVar` storage and buffered external writes through
`ContextExchange`, see [Interactive Contexts](@ref interactive_user).
