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
are below. Typed.jl is the inferred version of the steps. What a plan type provides (its getters, `rebuild_plan`) is in LoopAlgorithms/Interface.jl.
=#

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

`resolve` itself is compiled once (its result is not inferred; a caller gets `Any`). The steps are run by
`_resolve_plan`, compiled once per plan type, on a registry without a `UniqueKeyMap`; `resolve` puts the plan's map
into the registry at the end (`unique_key_map`, `with_keymap`), so a `Unique` handle the user holds is found from types
(`getregistry(la)[handle]`, `context(la)[handle]`). A plan's `Unique` handles are dynamic until here and numbered first
(`number_unique_ids`, untyped), so the same layout with new handles is the same plan type, and so are its registry and
context: nothing compiles again. The inferred version, for a caller that knows the plan type, is `_resolve_plan_typed` (Typed.jl).
"""
Base.@nospecializeinfer function resolve(@nospecialize(la::LoopSpec))
    _registry_field(la) isa NameSpaceRegistry && return la   # resolved; read untyped, as its type carries the map
    resolved = _resolve_plan(number_unique_ids(la))
    return with_keymap(resolved, unique_key_map(_registry_field(resolved)))
end

"""
Run the steps of resolving the unresolved `la` (see the top of this file) and return the resolved plan. Compiled once:
the steps walk the plan untyped, and the wrappers are made with `new_instance`, so a plan of a new type compiles only
step 1 (`build_registry_and_key_plan`, generated from its type).
"""
Base.@nospecializeinfer function _resolve_plan(@nospecialize(la::LoopSpec))
    if la isa FinalizedAlgorithm
        return finalstep(_resolve_plan(getfield(la, :inner)), getfield(la, :final))
    end
    if !(la isa LoopAlgorithm)
        # `LoopAlgorithm(la)` with its defaults; its keyword constructor would compile for each plan type.
        T = Core.apply_type(LoopAlgorithm, typeof(la), Tuple{}, Nothing, Nothing, Tuple{}, Tuple{}, getid(la))
        return _resolve_plan(new_instance(T, la, (), nothing, nothing, (), ()))
    end

    # 1. keys and namespaces; read with `getfield`, as destructuring compiles for each tuple type.
    registry_and_keyed = build_registry_and_key_plan(la)
    return _resolve_keyed_plan(getfield(registry_and_keyed, 2), getfield(registry_and_keyed, 1))
end

"""
Run steps 2 to 4 on `keyed_la`, a root wrapper that step 1 gave keys to with `registry`, and return it resolved, with the
`RootOption`s of its plan tree on it. Compiled once: the resolved wrapper is made with `new_instance`.
"""
Base.@nospecializeinfer function _resolve_keyed_plan(@nospecialize(keyed_la::LoopAlgorithm), @nospecialize(registry::NameSpaceRegistry))
    keyed_plan = getfield(keyed_la, :plan)
    options = _collect_root_options_untyped(keyed_plan)
    plan = _resolve_scopes(_resolve_wiring(keyed_plan, registry, (;)), NoScope, "")   # 3. routes, shares; 4. scopes
    # 2. share the registry, with the resolved plan and the root options: `_attach_registry`, `setfield` and `setoptions`.
    p = typeof(keyed_la).parameters    # {Plan, O, R, C, Inits, Overrides, id}
    T = Core.apply_type(LoopAlgorithm, typeof(plan), typeof(options), typeof(registry), p[4], p[5], p[6], p[7])
    return new_instance(T, plan, options, registry, getfield(keyed_la, :context), getfield(keyed_la, :inits), getfield(keyed_la, :overrides))
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
    # One registry needs one numbering of the `Unique` handles over all the plans.
    loopalgorithms = number_unique_ids((la1, la2, las...))
    registry, keyed_loopalgorithms = _build_shared_registry_and_key_plans(loopalgorithms)
    keymap = unique_key_map(registry)
    return map(keyed -> with_keymap(_resolve_keyed_plan(keyed, registry), keymap), keyed_loopalgorithms)
end

@inline resolve(loopalgorithms::Tuple{Vararg{LoopSpec}}) = resolve(loopalgorithms...)

"""Build one registry for several loop algorithms and return it with each algorithm's keyed plan tree."""
# TODO: unlike `resolve(la)`, the `resolve(la1, la2, ...)` calling this is compiled for every combination of plan types
# (no unspecialized entry), skips the `isresolved` check, and a `FinalizedAlgorithm` argument fails (`LoopAlgorithm(::FinalizedAlgorithm)` has no method). Route it
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
