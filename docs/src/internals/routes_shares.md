# [Routes and Shares Internals](@id routes_shares_internals)

`Route` and `Share` are plan options. Resolution happens when a plan is wrapped
and resolved as a concrete `LoopAlgorithm`.

Relevant files:

- Definitions: `src/RoutingInterface/RouteDef.jl`, `src/RoutingInterface/ShareDef.jl`
- Resolution backend: `src/RoutingInterface/Resolving.jl`, `src/RoutingInterface/Backend.jl`, `src/RoutingInterface/Sharing.jl`
- Plan integration: `src/LoopAlgorithms/PlanOptions.jl`, `src/LoopAlgorithms/Preparation/Constructor.jl`
- View integration: `src/Context/View/StructDef.jl`, `src/Context/View/Locations.jl`

## 1. Route Resolution

`Route` stores:

- source endpoint (`from`)
- target endpoint (`to`)
- routed source variable names
- local aliases in target view
- optional transform function
- optional reverse transform function
- precomputed `match_by` identities for from/to

`resolve_options(reg, routes...)` converts each route into:

- target subcontext name => tuple of resolved `Route` metadata, including
  source names, target aliases, transform, and reverse transform.

`to_sharedvar` resolves endpoints by matcher identity in the registry, then binds concrete source/target keys.

Transform details:

- `Route(...; transform = f)` or `Route(...; reverse_transform = g)` is
  restricted to exactly one mapping entry.
- That single mapping can still be multi-source by mapping `(:a, :b, ...) => :local_name`.
- At view-read time this becomes a `VarLocation` with tuple `originalname` and `func = f`, so the generated getter reads each source variable and calls `f(a, b, ...)`.
- At writeback time, transformed route aliases must have a reverse transform.
  Multi-source reverse transforms can return a tuple in source-variable order or
  a named tuple keyed by source variable name.

## 2. Share Resolution

`Share(a,b; directional=false)` is converted to `SharedContext` metadata:

- `a -> b`
- and also `b -> a` when non-directional.

This metadata is attached to the target child's `StepRouting`.

## 3. How Views See Them

When creating `SubContextView` locations (`src/Context/View/Locations.jl`):

- `SharedContext` contributes all variables from the shared subcontext.
- Route metadata contributes only specified routed vars, plus transform and
  reverse transform if provided.

Both become `VarLocation{:subcontext}` entries, so reads and writes are directed to the source subcontext.

That means returning a routed/shared variable from `step!` can update remote state, not only local state.

The view constructor reconstructs resolved route/share tuples from their
concrete tuple types. The runtime routing value selects the type-specialized
view, but the view does not depend on const-propagating route/share values.

## 4. Errors and Validation

If route/share endpoints are not present in the registry, resolution throws explicit errors listing available keys (see `to_sharedvar` and `to_sharedcontext`).

## 5. Relation to Packaging

During `Package(comp)`, routes are translated into `VarAliases` for internal subpackages (`src/Packaging/Constructor.jl`, `src/Packaging/Utils.jl`).

## 6. Plan-Local Wiring

Plain `Route`/`Share` options are stored on the plan node that contains them.
DSL-local route/share statements become child-aligned local wiring, so the
resolved `StepRouting` passed to a child is specific to that child location.

Nested plan routes remain local to the nested plan. A route/share assigned to a
nested plan child itself is rejected because nested plan nodes do not have their
own root context key; attach that route/share to a concrete child inside the
nested plan instead.

If both top-level and local routes expose the same target alias, local routes
take precedence for that child step.
