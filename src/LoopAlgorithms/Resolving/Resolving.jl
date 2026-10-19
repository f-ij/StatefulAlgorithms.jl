export resolve

#=
Resolving a plan: everything that can only be decided once the whole composition is known.

1. Registry: every algorithm and state in the tree gets a key (`Sensor_1`, `Sensor_2`, ...).
   Children are replaced by their raw algorithm and the key goes into the plan's `namespaces`.
   Calls (`Callable`) have no identity: they are not registered and share `:_captured_returns`.
   Nested wrappers (`LoopAlgorithm`, `FinalizedAlgorithm`) are replaced by their plan, so after this step every
   nested child that is a `LoopSpec` is an `AbstractPlan`.
2. The registry is attached to the root wrapper.
3. Wiring: route/share endpoints become context keys, and plan-wide wiring is copied into each
   child's slot.
4. Scopes: each plan node records (in its `PlanWiring` type) its scope, the declared locals and
   captured returns its children see by name (`Scope`), and routes that read them point at
   their slots.

5. Registry matchers: the registry stores each `Unique` handle with its `DoubleMatcher` (`registry_matchers`,
   Identifiable/UniquePlanIds.jl), so the handle the user holds finds its entry.

Steps 1 and 2 are in Registering.jl, step 3 in Wiring.jl, step 4 in Scopes.jl. `resolve` and the other entry points
are below. Typed.jl is the inferred version of the steps. What a plan type provides (its getters, `rebuild_plan`) is in LoopAlgorithms/Interface.jl.
=#

include("Registering.jl")
include("Wiring.jl")
include("Scopes.jl")
include("Typed.jl")          # the inferred resolve, `_resolve_plan_typed`

"""
Materialize a loop algorithm for context construction.

This wraps bare plan nodes in a concrete `LoopAlgorithm`, builds a registry,
keys the child algorithms, resolves the route/share wiring against that
registry, and collects the `RootOption`s of the plan tree. The returned value is always a runtime wrapper unless the input was a
`FinalizedAlgorithm`, in which case the finalized outer shape is preserved and
its inner loop is materialized.

`resolve` itself is compiled once (its result is not inferred; a caller gets `Any`). The steps are run by
`_resolve_plan`, compiled once per plan type; a plan's `Unique` handles are numbered when it is built
(`number_unique_ids`), so the same layout with new handles is the same plan type and compiles nothing again. Only the
last step, which puts the handles' uuids into the registry (`registry_matchers`), works per uuid, untyped. The inferred
version, for a caller that knows the plan type, is `_resolve_plan_typed` (Typed.jl).
"""
Base.@nospecializeinfer resolve(@nospecialize(la::LoopSpec)) = registry_matchers(_resolve_plan(la))

"""
Run the steps of resolving `la` (see the top of this file) and return the resolved plan. Compiled for the plan's type
(after id normalization, see `resolve`), so the steps it calls are compiled together with it; the steps themselves
walk the plan untyped.
"""
function _resolve_plan(la::LA) where {LA<:LoopSpec}
    if la isa FinalizedAlgorithm
        return finalstep(_resolve_plan(inneralgorithm(la)), finalfunction(la))
    end
    if !(la isa LoopAlgorithm)
        return _resolve_plan(LoopAlgorithm(la))
    end
    if isresolved(la)
        return la
    end

    registry, keyed_la = setup_registry_and_keyed_algos(la)   # 1. keys and namespaces
    return _resolve_keyed_plan(keyed_la, registry)
end

"""
Run steps 2 to 4 on `keyed_la`, a root wrapper that step 1 gave keys to with `registry`, and return it resolved, with the
`RootOption`s of its plan tree on it.
"""
function _resolve_keyed_plan(keyed_la::LA, registry::R) where {LA<:LoopAlgorithm, R<:NameSpaceRegistry}
    keyed_la = _attach_registry(keyed_la, registry)                      # 2. share the registry
    plan = _resolve_plan_wiring_tree(getplan(keyed_la), registry, (;))   # 3. routes, shares
    plan = _resolve_scopes(plan, NoScope, "")                            # 4. scopes
    return setoptions(setfield(keyed_la, :plan, plan), _root_options(keyed_la))
end

"""
    resolve(la1, la2, las...)
    resolve((la1, la2, las...))

Resolve several loop algorithms against one shared registry and return them resolved, in the same order. Their
algorithms get keys that do not clash across them (the second algorithm's `Sensor` is `Sensor_2`, not another
`Sensor_1`).

Meant for multi-stage runs: prepare several algorithms at once, then run each separately, each in its own process.
"""
function resolve(la1::LA1, la2::LA2, las::Vararg{LoopSpec}) where {LA1<:LoopSpec, LA2<:LoopSpec}
    # Each plan numbered its `Unique` handles on its own; one registry needs one numbering over all of them.
    loopalgorithms = number_unique_ids((la1, la2, las...))
    registry, keyed_loopalgorithms = _build_shared_registry_and_keyed_algos(loopalgorithms)
    return registry_matchers(map(keyed -> _resolve_keyed_plan(keyed, registry), keyed_loopalgorithms))
end

@inline resolve(loopalgorithms::Tuple{Vararg{LoopSpec}}) = resolve(loopalgorithms...)

"""Build one registry for several loop algorithms and return it with each algorithm's keyed plan tree."""
# TODO: unlike `resolve(la)`, the `resolve(la1, la2, ...)` calling this is compiled for every combination of plan types
# (no unspecialized entry), skips the `isresolved` check, and a `FinalizedAlgorithm` argument fails (`LoopAlgorithm(::FinalizedAlgorithm)` has no method). Route it
# through the same steps as `resolve(la)`.
Base.@nospecializeinfer function _build_shared_registry_and_keyed_algos(@nospecialize(loopalgorithms::Tuple))
    builder = RegistryBuilder()
    keyed = Vector{Any}(undef, nfields(loopalgorithms))
    for i in eachindex(keyed)
        la = getfield(loopalgorithms, i)
        keyed[i] = add_tree!(builder, la isa LoopAlgorithm ? la : LoopAlgorithm(la))
    end
    return registry(builder), Tuple(keyed)
end
