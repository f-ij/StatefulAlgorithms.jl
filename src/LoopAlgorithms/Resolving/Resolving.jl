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

Steps 1 and 2 are in Registering.jl, step 3 in Wiring.jl, step 4 in Scopes.jl. `resolve` and the other entry points
are below. NormalizeIds.jl makes plans that differ only in `Unique` ids one plan type, and Typed.jl is the inferred
version of the steps. What a plan type provides (its getters, `rebuild_plan`) is in LoopAlgorithms/Interface.jl.
=#

include("NormalizeIds.jl")
include("Registering.jl")
include("Wiring.jl")
include("Scopes.jl")
include("Typed.jl")          # the inferred resolve, `_resolve_plan_typed`; preserved, though `resolve` does not use it

"""
    resolve(la) -> resolved la

Resolve a loop algorithm or a bare plan (the steps at the top of this file) and return it resolved: a `LoopAlgorithm`
with its registry attached, its children keyed, its wiring and scopes resolved, and the `RootOption`s of its plan tree
on it. A bare plan is wrapped in a `LoopAlgorithm` first; a `FinalizedAlgorithm` stays one, with its inner loop
resolved. An already resolved `la` is returned as it is.

`resolve` itself is compiled once (its result is not inferred; a caller gets `Any`). Plans with `Unique` handles have
their random ids normalized first, so the same layout with new ids is the same plan type and compiles nothing again
(NormalizeIds.jl). The steps are then run by `_resolve_plan`, compiled once per plan type. The inferred version, for a
caller that knows the plan type, is `_resolve_plan_typed` (Typed.jl).
"""
Base.@nospecializeinfer function resolve(@nospecialize(la::LoopSpec))
    isresolved(la) && return la             # before `normalize_ids`, which walks the whole plan
    normalized, found = normalize_ids(la)
    found || return _resolve_plan(la)
    return normalized |> _resolve_plan |> restore_original_ids
end

"""
Run the steps of resolving the unresolved `la` (see the top of this file) and return the resolved plan. Compiled for
the plan's type (after id normalization, see `resolve`), so the steps it calls are compiled together with it; the steps
themselves walk the plan untyped.
"""
function _resolve_plan(la::LA) where {LA<:LoopSpec}
    if la isa FinalizedAlgorithm
        return finalstep(_resolve_plan(inneralgorithm(la)), finalfunction(la))
    end
    if !(la isa LoopAlgorithm)
        return _resolve_plan(LoopAlgorithm(la))
    end

    registry, keyed_la = build_registry_and_key_plan(la)   # 1. keys and namespaces
    return _resolve_keyed_plan(keyed_la, registry)
end

"""
Run steps 2 to 4 on `keyed_la`, a root wrapper that step 1 gave keys to with `registry`, and return it resolved, with the
`RootOption`s of its plan tree on it.
"""
function _resolve_keyed_plan(keyed_la::LA, registry::R) where {LA<:LoopAlgorithm, R<:NameSpaceRegistry}
    keyed_la = _attach_registry(keyed_la, registry)                      # 2. share the registry
    plan = _resolve_wiring(getplan(keyed_la), registry, (;))   # 3. routes, shares
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
Nothing in the package calls it yet; it is kept for making separate plans runnable separately (see the TODO below).
"""
function resolve(la1::LA1, la2::LA2, las::Vararg{LoopSpec}) where {LA1<:LoopSpec, LA2<:LoopSpec}
    loopalgorithms = (la1, la2, las...)
    registry, keyed_loopalgorithms = _build_shared_registry_and_key_plans(loopalgorithms)
    return map(keyed -> _resolve_keyed_plan(keyed, registry), keyed_loopalgorithms)
end

@inline resolve(loopalgorithms::Tuple{Vararg{LoopSpec}}) = resolve(loopalgorithms...)

"""Build one registry for several loop algorithms and return it with each algorithm's keyed plan tree."""
# TODO: unlike `resolve(la)`, the `resolve(la1, la2, ...)` calling this is compiled for every combination of plan types
# (no unspecialized entry), skips the `isresolved` check and `Unique` id normalization (so each new id compiles it
# again), and a `FinalizedAlgorithm` argument fails (`LoopAlgorithm(::FinalizedAlgorithm)` has no method). Route it
# through the same steps as `resolve(la)`.
Base.@nospecializeinfer function _build_shared_registry_and_key_plans(@nospecialize(loopalgorithms::Tuple))
    builder = RegistryBuilder()
    keyed = Vector{Any}(undef, nfields(loopalgorithms))
    for i in eachindex(keyed)
        la = getfield(loopalgorithms, i)
        keyed[i] = register_tree!(builder, la isa LoopAlgorithm ? la : LoopAlgorithm(la))
    end
    return registry(builder), Tuple(keyed)
end
