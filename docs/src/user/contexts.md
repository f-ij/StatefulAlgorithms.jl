# [Contexts and Indexing](@id contexts_user)

## What an algorithm sees

The full runtime data object is a `ProcessContext`.

Each registered algorithm or state owns one named part of that context. That
part is a `SubContext`.

Entity methods receive a `SubContextView`, not the raw `ProcessContext`. A view
shows the values that the current entity is allowed to read.

An algorithm's view exposes:

- its own state (its subcontext),
- its routes and shares.

It does not see the declared locals or captured returns of the block it runs in (see
[Values That Live For A Run](#Values-That-Live-For-A-Run)) unless they are wired to it. The DSL wires every argument
of an algorithm statement, so `Algo(x)` sees `x`. A plain function call (`y = f(x)`) sees the block's declared locals
and captured returns directly.

## Reading Variables

```julia
@StepAlgorithm function MyAlgo(state, dt)
    # ...
    return
end
```

Each argument of a `@StepAlgorithm` is read from the view by its name at every step (a keyword argument with its
default when the view does not have it). In a deprecated hand-written `step!(::MyAlgo, context)`, `context.name`
and destructuring (`(; state, dt) = context`) read from the view.

## Writing Variables

A `@StepAlgorithm` writes a name back with `@update name = …`; its return is a value, not a write.

The rest of this section is about hooks written by hand, which return a `NamedTuple`: `cleanup`, and the
**deprecated** hand-written `init` and `step!` (define algorithms with `@StepAlgorithm` instead). The phase changes
what that return means.

1. `init` defines the persistent fields owned by the entity and replaces its
   initially empty subcontext with those fields.
2. `step!` updates existing fields of its own state, routes, or shares. A new name is a
   subcontext return: it is kept for one step only when something reads it later, and it
   is not added to the persistent subcontext.
3. `cleanup` uses the same mapped-write mechanism as `step!`; its returned
   existing fields are committed during finalization.

Changing the type of an existing persistent field is rejected. If a value must
change without changing context shape, initialize a suitably typed `Ref` or
mutable buffer and update its contents.

If `Target` sees `source_value` through a route and updates it (`@update source_value = 2.0`, or a hand-written
`step!` returning `(; source_value = 2.0)`), the stored value in the source subcontext is updated.
If a value must persist, create its field during `init`, with `@managed`, or
with `@state`, then update that existing name from `step!`.

## Top-Level Context Access

From a process:

```julia
ctx = context(p)
```

`context(p)` and `getcontext(p)` both return the process's current stored
context. `getcontext(p, key)` is shorthand for indexing that context by `key`.

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

## Values That Live For A Run

Besides the stored (persistent) state, a run has values that are not stored with the process:

| Kind | Lifetime | On pause |
|---|---|---|
| inputs (`@input`) | the run, read-only | kept |
| declared locals (`local x`, `local x::T`; `Local`) | the run | kept |
| captured returns (`y = f(x)`) | one step of the block that assigns it | dropped |
| subcontext returns (an algorithm's return value, `_return`; for a hand-written `step!`, the returned names that are not its state) | one step of the block the algorithm is in | dropped |

An algorithm reads them through its wires (the DSL wires every argument); a plain function call reads them by name.
Every block (a composite or routine, nested ones too) is a scope, as a `for` loop body is in Julia: its children can
read the declared locals and captured returns of the block and of the blocks around it, and a name declared in an inner block hides the same name of an outer one. Assigning a name that is
already visible, in a block or a block inside it, updates it. A captured return is unset each time its block is
entered. A name assigned on a schedule (`y = @every 3 f()`) has to be declared first (`local y`, or `Local` outside
the DSL): it then keeps its last value between steps, and reading it before its first assignment is an
`UndefRefError`. The process and the lifetime are not visible to steps; `init`
gets the lifetime for sizing (`processsizehint!`). For selector syntax, see [Vars (`Var` Selectors)](@ref vars_user).

For immediate `InteractiveVar` storage and buffered external writes through
`ContextExchange`, see [Interactive Contexts](@ref interactive_user).
