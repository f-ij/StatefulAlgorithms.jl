# [Routes, Shares, and Redirects](@id routes_shares_user)

`Route`, `Share`, and `Redirect` make values from one algorithm or state visible
to another.

Each algorithm or state owns a subcontext: its named part of the full process
context. A route exposes selected names from one subcontext. A share exposes all
names from one subcontext. A redirect makes a target-owned field read and
write through a source-owned field after initialization.

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

If the target may update the routed alias and you want that update written back
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
updates `input` (`@update input = new_input` in a `@StepAlgorithm`, or a hand-written `step!` returning
`(; input = new_input)`), `Source.value` is updated with `new_input / 2`.

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
- Updating a transformed route alias without `reverse_transform` is an error,
  because the writeback would otherwise be ambiguous.

## `Share`: Whole Subcontext

Expose all source variables to target:

```julia
Share(Source, Target)
```

Default is bidirectional (`directional = false`), so both sides can read the
other side's values. Use `directional = true` for a one-way share from the first
argument to the second.

A route given the same name as a field of the target's own state hides that field: the target reads and writes the
route's source instead. A share that gives the target a name it also has from its own state or from a route is an
error, thrown the first time the target's step runs.

## `Redirect`: Persistent Field Backing

Use `Redirect` when one subcontext should keep its local field name, but the
field should be backed by another subcontext's storage:

```julia
algo = CompositeAlgorithm(
    Source, Target,
    (1, 1),
    Redirect(Source => Target, :value),
)
```

After `init`, `Target` still sees `context.value`, but reads and writes go
through `Source.value`.

You can also alias the target field name:

```julia
Redirect(Source => Target, :value => :input_value)
```

In that case, `Target` sees `context.input_value`, backed by `Source.value`.

Unlike `Route`, `Redirect` is materialized into the persistent context. The
target field is initialized normally, then replaced by a `RedirectedVar` marker
that points at the source field. This makes a redirect useful when a target
algorithm requires a local field to exist during initialization, but the runtime
value should be shared with a source field afterwards.

Constraints:

- A redirect must name at least one variable mapping.
- Source and target subcontexts, and their variables, must exist after init.
- A field cannot redirect to itself.

## Read and Write Semantics

Routed and shared names point back to stored values. If the target updates one
of those names (`@update` in a `@StepAlgorithm`, or a hand-written `step!` returning it in a named tuple), the
source subcontext is updated.

This enables coupling patterns like:

- algorithm B reading and damping algorithm A's `velocity`, then updating `velocity`.

Redirect-backed fields behave the same way from the target algorithm's point
of view: updating the redirected local name writes through to the source field
while preserving the target's persistent redirect marker.

## Plan-Wide and Child-Local Routes

An explicit `@route` statement adds a plan-wide route to the containing
composite or routine. A route created by a child call, such as
`sink(value = produced)`, belongs only to that child entry. This lets repeated
uses of the same algorithm have different call-local inputs.

Use `@context` when an explicit route needs to name a field owned inside a
nested plan.

Example:

```julia
inner = @Routine begin
    @alias source = Source
    source()
end

@CompositeAlgorithm begin
    @context c1 = inner()
    @alias sink = Sink
    sink()
    @route c1.source.value => sink.value
end
```

If a child-call route and an explicit `@route` expose the same target alias, the
child-call route takes precedence for that child entry.
