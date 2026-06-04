# [Routes and Shares](@id routes_shares_user)

`Route` and `Share` make values from one algorithm or state visible to another.

Each algorithm or state owns a subcontext: its named part of the full process
context. A route exposes selected names from one subcontext. A share exposes all
names from one subcontext.

## Referencing Algorithms

Recap:

- Use the same reference style you used in composition (type, saved instance, or saved `Unique` variable).
- Do not target with a fresh object unless that exact object was inserted in the composition.

For full examples, see [Referencing Algorithms](@ref referencing_algorithms_user).

## `Route`: Specific Variables

Route selected variables from source to target, optionally aliased:

```julia
CompositeAlgorithm(
    Source, Target,
    (1, 1),
    Route(Source => Target, :value => :input_value),
)
```

Target sees `context.input_value`.

If no alias is given, the target sees the same name as the source.

### Transform Route Values

You can provide `transform = f` (single mapping route) to expose transformed source values:

```julia
Route(Source => Target, :series => :latest, transform = x -> x[end])
```

If the target may return the routed alias and you want that return written back
through the transformed route, provide `reverse_transform = g`:

```julia
Route(
    Source => Target,
    :value => :input,
    transform = x -> 2x,
    reverse_transform = y -> y / 2,
)
```

In this example, `Target` reads `context.input == 2 * Source.value`. If `Target`
returns `(; input = new_input)`, `Source.value` is updated with
`new_input / 2`.

### Transform From Multiple Source Variables

A transform route can also read multiple source variables by using a tuple on the left-hand side:

```julia
Route(
    Source => Target,
    (:x, :y) => :norm_xy,
    transform = (x, y) -> sqrt(x^2 + y^2),
    reverse_transform = norm_xy -> (; x = norm_xy, y = 0.0),
)
```

Important constraints from the current implementation:

- If `transform` or `reverse_transform` is provided, the route must define exactly one mapping.
- Multi-source reverse transforms may return a tuple in source-variable order or
  a named tuple keyed by source variable name.
- Returning a transformed route alias without `reverse_transform` is an error,
  because the writeback would otherwise be ambiguous.

## `Share`: Whole Subcontext

Expose all source variables to target:

```julia
Share(Source, Target)
```

Default is bidirectional (`directional = false`), so both sides can read the
other side's values. Use `directional = true` for a one-way share from the first
argument to the second.

## Read and Write Semantics

Routed and shared names point back to stored values. If the target returns one
of those names from `step!`, the source subcontext can be updated.

This enables coupling patterns like:

- algorithm B reading and damping algorithm A's `velocity`, then returning updated `velocity`.

## Plan-Local Routes

Routes belong to the plan node where they are declared. In the DSL, a route
statement inside a composite/routine is attached to that local child step, so
the same algorithm type can be reused elsewhere with different local wiring.

Example:

```julia
@CompositeAlgorithm begin
    c1 = @CompositeAlgorithm begin
        inner = Source()
    end
    sink = Sink()
    @route c1.inner.value => sink.value
end
```

If a local route and a broader route expose the same target alias, the local
route takes precedence for that child step.
