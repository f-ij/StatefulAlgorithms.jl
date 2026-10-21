# [Routes, Shares, and Redirects Internals](@id routes_shares_internals)

`Route` and `Share` are wiring: a plan keeps them in its `wiring`, plan-wide or for
one child, and their endpoints are resolved when the plan is wrapped and resolved as
a concrete `LoopAlgorithm`. `Redirect` is an option, a `RootOption`: a plan keeps it in
its `options`, `resolve` collects it from every plan in the tree, and it is
materialized after lifecycle init has created the persistent context.

Relevant files:

- Definitions: `src/RoutingInterface/RouteDef.jl`, `src/RoutingInterface/ShareDef.jl`, `src/RoutingInterface/RedirectDef.jl`
- Resolution backend: `src/RoutingInterface/Resolving.jl`, `src/RoutingInterface/Backend.jl`, `src/RoutingInterface/Sharing.jl`
- Plan integration: `src/LoopAlgorithms/PlanOptions.jl`, `src/LoopAlgorithms/Resolving/` (`Resolving.jl`, step 3 in `Wiring.jl`)
- Redirect materialization: `src/LoopAlgorithms/Redirect/Materialization.jl`, cycle check: `src/LoopAlgorithms/Redirect/Checking.jl`
- View integration: `src/Context/View/StructDef.jl`, `src/Context/View/Locations.jl`

## 1. Route Resolution

`Route` stores:

- source-namespace ref (`source_ref`)
- target-namespace ref (`target_ref`)
- source field names
- target field names (aliases) in the target view
- optional transform function
- optional reverse transform function
- precomputed `match_by` identities for the source and target namespaces (`source_match_by`, `target_match_by`)

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

This metadata is inlaid into the target child's resolved `Wiring` bucket and is
read through a `PlanWiringView` while that child executes.

## 3. Redirect Materialization

`Redirect` stores:

- source-namespace ref (`source_ref`)
- target-namespace ref (`target_ref`)
- source field names
- target field names (aliases)
- precomputed matcher identities for the source and target namespaces (`source_match_by`, `target_match_by`)

`resolve_redirect(reg, redirect)` resolves endpoints against the
namespace registry and returns a resolved `Redirect` whose endpoint identities
are concrete subcontext names.

Redirect is not stored in the route/share `PlanWiring`. After loop-algorithm init,
`apply_redirect_specs(context, la)` resolves each root redirect and rewrites
the target persistent field to a `RedirectedVar(VarLocation{:state}(...))`
marker. The source and target fields must already exist in the initialized
context, and self-redirect is rejected.

`partialinit` applies redirect materialization again after rebuilding the
targeted subcontexts, so redirect markers are restored when an affected
field is reinitialized.

## 4. How Views See Them

When creating `SubContextView` locations (`src/Context/View/Locations.jl`):

- `SharedContext` contributes all variables from the shared subcontext.
- Route metadata contributes only specified routed vars, plus transform and
  reverse transform if provided.
- Local fields whose storage type is `RedirectedVar` redirect their local
  `VarLocation` to the stored backing location.

Shared fields and routes from persistent entity subcontexts become
`VarLocation{:state}` entries. Routes whose source is `:_inputs` or
`:_captured_returns` become `VarLocation{:runtime}` entries and read from the separate
loop-local runtime context. Redirect-backed locals retain the location kind
of their stored backing location.

Returning a routed or shared variable backed by persistent state can therefore
update the remote source field, not only local state.

The view constructor reconstructs resolved route/share tuples from their
concrete tuple types. The runtime routing value selects the type-specialized
view, but the view does not depend on const-propagating route/share values.
Redirect-backed local locations are discovered from the persistent context
field type instead of from runtime routing metadata.

## 5. Errors and Validation

If route/share endpoints are not present in the registry, resolution throws explicit errors listing available keys (see `to_sharedvar` and `to_sharedcontext`).

Redirect materialization throws explicit errors when source/target
subcontexts or variables are absent after init.

## 6. Relation to Packaging

During `Package(comp)`, routes are translated into `VarAliases` for internal subpackages (`src/Packaging/Constructor.jl`, `src/Packaging/Utils.jl`).

## 7. Plan-Local Wiring

Plain `Route`/`Share` options are plan-wide wiring on the plan node that contains
them. During resolution, inherited plan-wide wiring is inlaid into the matching
concrete child buckets.

Routes and shares produced by a DSL child call, such as
`sink(value = produced)`, are wrapped as `LocalPlanOption` values and stored in
that child's bucket. The resolved `PlanWiringView` therefore exposes the exact
`Wiring` for the current child path.

Nested plan routes remain local to the nested plan. A route/share assigned to a
nested plan child itself is rejected because nested plan nodes do not have their
own root context key; attach that route/share to a concrete child inside the
nested plan instead.

If both an explicit plan-wide route and child-call wiring expose the same target
alias, the child-call route occludes the plan-wide route for that child.
