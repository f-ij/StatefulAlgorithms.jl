# [Routes, Shares, and Replacements Internals](@id routes_shares_internals)

`Route`, `Share`, and `Replace` are plan options. Route/share resolution happens
when a plan is wrapped and resolved as a concrete `LoopAlgorithm`. Replacement
resolution is stored as a root option and materialized after lifecycle init has
created the persistent context.

Relevant files:

- Definitions: `src/RoutingInterface/RouteDef.jl`, `src/RoutingInterface/ShareDef.jl`, `src/RoutingInterface/ReplaceDef.jl`
- Resolution backend: `src/RoutingInterface/Resolving.jl`, `src/RoutingInterface/Backend.jl`, `src/RoutingInterface/Sharing.jl`
- Plan integration: `src/LoopAlgorithms/PlanOptions.jl`, `src/LoopAlgorithms/Preparation/Constructor.jl`
- Replacement materialization: `src/LoopAlgorithms/ReplaceMaterialization.jl`
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

## 3. Replacement Materialization

`Replace` stores:

- source endpoint (`from`)
- target endpoint (`to`)
- source variable names
- target aliases
- precomputed matcher identities for from/to

`resolve_replacement(reg, replacement)` resolves endpoints against the
namespace registry and returns a resolved `Replace` whose endpoint identities
are concrete subcontext names.

Replacement is not stored in `StepRouting`. After loop-algorithm init,
`apply_replace_specs(context, la)` resolves each root replacement and rewrites
the target persistent field to a `ReplacedVar(VarLocation{:subcontext}(...))`
marker. The source and target fields must already exist in the initialized
context, and self-replacement is rejected.

`partialinit` applies replacement materialization again after rebuilding the
targeted subcontexts, so replacement markers are restored when an affected
field is reinitialized.

## 4. How Views See Them

When creating `SubContextView` locations (`src/Context/View/Locations.jl`):

- `SharedContext` contributes all variables from the shared subcontext.
- Route metadata contributes only specified routed vars, plus transform and
  reverse transform if provided.
- Local fields whose storage type is `ReplacedVar` redirect their local
  `VarLocation` to the stored backing location.

Both become `VarLocation{:subcontext}` entries, so reads and writes are directed to the source subcontext.

That means returning a routed/shared variable from `step!` can update remote state, not only local state.

The view constructor reconstructs resolved route/share tuples from their
concrete tuple types. The runtime routing value selects the type-specialized
view, but the view does not depend on const-propagating route/share values.
Replacement-backed local locations are discovered from the persistent context
field type instead of from runtime routing metadata.

## 5. Errors and Validation

If route/share endpoints are not present in the registry, resolution throws explicit errors listing available keys (see `to_sharedvar` and `to_sharedcontext`).

Replacement materialization throws explicit errors when source/target
subcontexts or variables are absent after init.

## 6. Relation to Packaging

During `Package(comp)`, routes are translated into `VarAliases` for internal subpackages (`src/Packaging/Constructor.jl`, `src/Packaging/Utils.jl`).

## 7. Plan-Local Wiring

Plain `Route`/`Share` options are stored on the plan node that contains them.
DSL-local route/share statements become child-aligned local wiring, so the
resolved `StepRouting` passed to a child is specific to that child location.

Nested plan routes remain local to the nested plan. A route/share assigned to a
nested plan child itself is rejected because nested plan nodes do not have their
own root context key; attach that route/share to a concrete child inside the
nested plan instead.

If both top-level and local routes expose the same target alias, local routes
take precedence for that child step.
