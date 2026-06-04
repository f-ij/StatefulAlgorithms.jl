export resolve

"""Child-count threshold where registry construction switches to batch insertion."""
const _REGISTRY_BATCH_CHILD_LIMIT = 16

"""
Materialize a loop algorithm for context construction.

This wraps bare plan nodes in a concrete `LoopAlgorithm`, builds a registry,
keys the child algorithms, and resolves route/share options against that
registry. The returned value is always a runtime wrapper unless the input was a
`FinalizedAlgorithm`, in which case the finalized outer shape is preserved and
its inner loop is materialized.
"""
@inline function resolve(la::LA) where {LA<:AbstractLoopAlgorithm}
    if la isa FinalizedAlgorithm
        return finalstep(resolve(inneralgorithm(la)), finalfunction(la))
    end
    if !(la isa LoopAlgorithm)
        return resolve(LoopAlgorithm(la))
    end
    if isresolved(la)
        return la
    end

    registry, keyed_la = setup_registry_and_keyed_algos(la)
    keyed_la = attach_registry_to_tree(keyed_la, registry)
    keyed_la = resolve_plan_wiring(keyed_la, registry)
    return setoptions(keyed_la, _root_loop_options(la))
end

@inline function setup_registry_and_keyed_algos(la::LoopAlgorithm)
    registry = NameSpaceRegistry()

    # States are context-owned entries. They are registered first so the final
    # registry keeps the same ordering as `setup_registry`.
    states = flat_states(la)
    multipliers = ntuple(i -> 1, length(states))
    registry = addall(registry, states, multipliers)

    registry, named_plan = add_algos_to_registry(registry, getplan(la), 1.0)
    return registry, setfield(la, :plan, named_plan)
end

@inline function add_algos_to_registry(registry::R, la::LA, multiplier) where {R<:NameSpaceRegistry, LA<:Union{CompositeAlgorithm, Routine}}
    funcs = getalgos(la)
    algo_multipliers = multiplier .* multipliers(la)
    registry, raw_funcs, namespaces = add_algo_tuple_to_registry(registry, funcs, algo_multipliers)
    return registry, setfield(rebuild_loopalgorithm_funcs(la, raw_funcs), :namespaces, namespaces)
end

@inline function add_algos_to_registry(registry::R, la::LA, multiplier) where {R<:NameSpaceRegistry, LA<:AbstractLoopAlgorithm}
    funcs = getalgos(la)
    algo_multipliers = multiplier .* multipliers(la)
    registry, raw_funcs, _ = add_algo_tuple_to_registry(registry, funcs, algo_multipliers)
    return registry, rebuild_loopalgorithm_funcs(la, raw_funcs)
end

@inline add_algo_tuple_to_registry(registry::R, ::Tuple{}, ::Tuple{}) where {R<:NameSpaceRegistry} = registry, (), ()

"""Return whether every child is a raw `FuncWrapper` value."""
function _all_funcwrapper_values(funcs::Funcs) where {Funcs<:Tuple}
    for func in funcs
        func isa FuncWrapper || return false
    end
    return true
end

"""Return the same autokey shape used for raw `FuncWrapper` DSL children."""
@inline function _funcwrapper_autokey(func::F, idx::Int) where {F<:FuncWrapper}
    return IdentifiableAlgo(func, Symbol(:FuncWrapper_, idx))
end

"""Add a large tuple of raw `FuncWrapper`s to the registry in one pass.

Large DSL function-call chains usually produce many unique `FuncWrapper`
children. Adding them one-by-one creates and compiles one intermediate registry
tuple type per child; batching keeps the same final registry shape while only
materializing the final `RegistryTypeEntry{FuncWrapper}` once.
"""
function _add_funcwrapper_tuple_to_registry(registry::R, funcs::Funcs, multipliers::Multipliers) where {R<:NameSpaceRegistry, Funcs<:Tuple, Multipliers<:Tuple}
    entries = ntuple(i -> _funcwrapper_autokey(getfield(funcs, i), i), length(funcs))
    multiplier_values = Float64[]
    sizehint!(multiplier_values, length(multipliers))
    lookup = Dict{Any, Int}()

    # Mirror `RegistryTypeEntry.add`: store multipliers and dynamic lookup for
    # each autokeyed wrapper, but avoid building every intermediate entry tuple.
    for i in eachindex(entries)
        push!(multiplier_values, Float64(getfield(multipliers, i)))
        lookup[match_by(getfield(entries, i))] = i
    end

    entry = RegistryTypeEntry{FuncWrapper, typeof(entries)}(entries, multiplier_values, lookup)
    registry_entries = (getentries(registry)..., entry)
    namespaces = ntuple(i -> Namespace{getkey(getfield(entries, i))}(), length(entries))
    return NameSpaceRegistry{typeof(registry_entries)}(registry_entries), funcs, namespaces
end

@inline function add_algo_tuple_to_registry(registry::R, funcs::F, multipliers::M) where {R<:NameSpaceRegistry, F<:Tuple, M<:Tuple}
    if length(funcs) > _REGISTRY_BATCH_CHILD_LIMIT &&
       isnothing(find_typeidx(registry, FuncWrapper)) &&
       _all_funcwrapper_values(funcs)
        return _add_funcwrapper_tuple_to_registry(registry, funcs, multipliers)
    end

    registry, raw_head, name_head = add_algo_to_registry(registry, first(funcs), first(multipliers))
    registry, raw_tail, name_tail = add_algo_tuple_to_registry(registry, Base.tail(funcs), Base.tail(multipliers))
    return registry, (raw_head, raw_tail...), (name_head, name_tail...)
end

@inline function add_algo_to_registry(registry::R, algo::LA, multiplier) where {R<:NameSpaceRegistry, LA<:AbstractLoopAlgorithm}
    inner = algo isa LoopAlgorithm ? getplan(algo) : algo
    registry, plan = add_algos_to_registry(registry, inner, multiplier)
    return registry, plan, Namespace{nothing}()
end

@inline function add_algo_to_registry(registry::R, algo::IA, multiplier) where {F<:AbstractLoopAlgorithm, R<:NameSpaceRegistry, IA<:AbstractIdentifiableAlgo{F}}
    registry, plan = add_algos_to_registry(registry, getalgo(algo), multiplier)
    return registry, plan, Namespace{nothing}()
end

@inline function add_algo_to_registry(registry::R, algo::A, multiplier) where {R<:NameSpaceRegistry, A}
    registry, keyed_algo = add(registry, algo, multiplier)
    return registry, getalgo(keyed_algo), Namespace{getkey(keyed_algo)}()
end

@inline function rebuild_loopalgorithm_funcs(la::LA, funcs::F) where {LA<:Union{CompositeAlgorithm, Routine}, F<:Tuple}
    return setfield(la, :funcs, funcs)
end

@inline function rebuild_loopalgorithm_funcs(la::LA, funcs::F) where {LA<:AbstractLoopAlgorithm, F}
    return setfield(la, :funcs, funcs)
end

@inline function rebuild_loopalgorithm_funcs(la::LoopAlgorithm, funcs::F) where {F}
    return setfield(la, :plan, rebuild_loopalgorithm_funcs(getplan(la), funcs))
end

@inline function rebuild_loopalgorithm_funcs(fa::FA, funcs::F) where {FA<:FinalizedAlgorithm, F}
    return finalstep(rebuild_loopalgorithm_funcs(inneralgorithm(fa), funcs), finalfunction(fa))
end

@inline function attach_registry_to_tree(la::LoopAlgorithm, registry::R) where {R<:NameSpaceRegistry}
    plan = attach_registry_to_tree(getplan(la), registry)
    return _attach_registry(setfield(la, :plan, plan), registry)
end

@inline function attach_registry_to_tree(la::LA, registry::R) where {LA<:AbstractLoopAlgorithm, R<:NameSpaceRegistry}
    funcs = map(getalgos(la)) do func
        func isa AbstractLoopAlgorithm ? attach_registry_to_tree(func, registry) : func
    end
    return rebuild_loopalgorithm_funcs(la, funcs)
end

@inline function attach_registry_to_tree(fa::FA, registry::R) where {FA<:FinalizedAlgorithm, R<:NameSpaceRegistry}
    return finalstep(attach_registry_to_tree(inneralgorithm(fa), registry), finalfunction(fa))
end

@inline resolve_plan_wiring(la, ::NameSpaceRegistry) = la

@inline function resolve_plan_wiring(la::LoopAlgorithm, registry::NameSpaceRegistry)
    return setfield(la, :plan, _resolve_plan_wiring_tree(getplan(la), registry, (;)))
end

"""Resolve a plan tree and inlay inherited global wiring into concrete children."""
function _resolve_plan_wiring_tree(la::LA, registry::NameSpaceRegistry, inherited_global::NamedTuple) where {LA<:Union{CompositeAlgorithm, Routine}}
    raw_wiring = getwiring(la)

    # Global wiring is grouped by resolved target namespace once per plan node.
    # Child buckets below receive the relevant global wiring already inlaid, so
    # `step!` never has to merge plan-global and child-specific wiring.
    own_global = _resolve_wiring_grouped(registry, global_wiring(raw_wiring))
    combined_global = _merge_global_wiring(inherited_global, own_global)

    # Resolve nested plans first. Their own `PlanWiring` then becomes the
    # child-indexed value passed to that child during parent stepping.
    funcs = ntuple(length(getalgos(la))) do i
        child = getalgo(la, i)
        if child isa AbstractLoopAlgorithm
            return _resolve_plan_wiring_tree(child, registry, combined_global)
        end
        return child
    end
    la = rebuild_loopalgorithm_funcs(la, funcs)

    resolved_children = ntuple(length(funcs)) do i
        child = funcs[i]
        if child isa AbstractLoopAlgorithm
            return getwiring(child)
        end
        target = plan_child_namespace(la, i)
        bucket = getfield(child_wiring(raw_wiring), i)

        # Concrete children receive a single resolved `Wiring`: inherited global
        # wiring for their namespace, occluded by child-scoped routes.
        target_global = get(combined_global, target, Wiring())
        target_child = _resolve_child_wiring_bucket(registry, bucket, target)
        resolved = merge_wiring(target_global, target_child)
        return resolved
    end

    return setfield(la, :wiring, PlanWiring(combined_global, resolved_children))
end

@inline function resolve_plan_wiring(fa::FA, registry::NameSpaceRegistry) where {FA<:FinalizedAlgorithm}
    return finalstep(resolve_plan_wiring(inneralgorithm(fa), registry), finalfunction(fa))
end

"""Append target-keyed `Wiring` groups for a tuple of namespace keys."""
@inline _append_wiring_group_keys(grouped::NamedTuple, ::Tuple{}, route_groups::NamedTuple, share_groups::NamedTuple) = grouped
@inline function _append_wiring_group_keys(grouped::NamedTuple, keys::Keys, route_groups::NamedTuple, share_groups::NamedTuple) where {Keys<:Tuple}
    key = first(keys)
    if key in propertynames(grouped)
        return _append_wiring_group_keys(grouped, Base.tail(keys), route_groups, share_groups)
    end
    bucket = Wiring(get(route_groups, key, ()), get(share_groups, key, ()))
    return _append_wiring_group_keys((; grouped..., key => bucket), Base.tail(keys), route_groups, share_groups)
end

"""Resolve a `Wiring` bucket and group it by target namespace."""
function _resolve_wiring_grouped(registry::NameSpaceRegistry, wiring::Wiring)
    share_groups = resolve_options(registry, shares(wiring)...)
    route_groups = resolve_options(registry, routes(wiring)...)
    grouped = _append_wiring_group_keys((;), propertynames(share_groups), route_groups, share_groups)
    return _append_wiring_group_keys(grouped, propertynames(route_groups), route_groups, share_groups)
end

"""Return already grouped global wiring unchanged."""
_resolve_wiring_grouped(::NameSpaceRegistry, grouped::NamedTuple) = grouped

"""Append merged global wiring for a tuple of namespace keys."""
@inline _append_merged_global_keys(merged::NamedTuple, ::Tuple{}, left::NamedTuple, right::NamedTuple) = merged
@inline function _append_merged_global_keys(merged::NamedTuple, keys::Keys, left::NamedTuple, right::NamedTuple) where {Keys<:Tuple}
    key = first(keys)
    if key in propertynames(merged)
        return _append_merged_global_keys(merged, Base.tail(keys), left, right)
    end
    bucket = merge_wiring(get(left, key, Wiring()), get(right, key, Wiring()))
    return _append_merged_global_keys((; merged..., key => bucket), Base.tail(keys), left, right)
end

"""Merge grouped global wiring, with right-side route aliases occluding left."""
function _merge_global_wiring(left::NamedTuple, right::NamedTuple)
    merged = _append_merged_global_keys((;), propertynames(left), left, right)
    return _append_merged_global_keys(merged, propertynames(right), left, right)
end

"""Resolve a child wiring bucket for one concrete target namespace."""
function _resolve_child_wiring_bucket(registry::NameSpaceRegistry, bucket::Wiring, target::Symbol)
    grouped = _resolve_wiring_grouped(registry, bucket)
    return get(grouped, target, Wiring())
end

"""Collect unresolved options from nested child plan nodes."""
@inline _plan_tree_child_options(::Tuple{}) = ()
@inline function _plan_tree_child_options(children::Children) where {Children<:Tuple}
    child = first(children)
    head_options = child isa AbstractLoopAlgorithm ? _plan_tree_options(child) : ()
    return (head_options..., _plan_tree_child_options(Base.tail(children))...)
end

"""Collect unresolved options stored throughout one plan tree."""
function _plan_tree_options(la::LA) where {LA<:AbstractLoopAlgorithm}
    nested = _plan_tree_child_options(getalgos(la))
    return (getoptions(la)..., nested...)
end

@inline _plan_tree_options(la::LoopAlgorithm) = (_plan_tree_options(getplan(la))..., getoptions(la)...)

@inline _unresolved_options(la::LoopAlgorithm) = (_plan_tree_options(getplan(la))..., getoptions(la)...)
@inline _unresolved_options(la::LA) where {LA<:AbstractLoopAlgorithm} = _plan_tree_options(la)

@inline function _resolve_options(la::LA) where {LA<:AbstractLoopAlgorithm}
    resolved = resolve(la)
    return _resolved_wiring_maps(getwiring(resolved))
end

"""Collect resolved share and route maps from plan wiring for inspection."""
function _resolved_wiring_maps(wiring::PlanWiring)
    share_map = (;)
    route_map = (;)
    for target in propertynames(global_wiring(wiring))
        bucket = getproperty(global_wiring(wiring), target)
        share_map = (; share_map..., target => _append_unique_wiring_values(get(share_map, target, ()), shares(bucket)))
        route_map = (; route_map..., target => _append_unique_wiring_values(get(route_map, target, ()), routes(bucket)))
    end
    for bucket in child_wiring(wiring)
        if bucket isa PlanWiring
            child_share_map, child_route_map = _resolved_wiring_maps(bucket)
            for target in propertynames(child_share_map)
                share_map = (; share_map..., target => _append_unique_wiring_values(get(share_map, target, ()), getproperty(child_share_map, target)))
            end
            for target in propertynames(child_route_map)
                route_map = (; route_map..., target => _append_unique_wiring_values(get(route_map, target, ()), getproperty(child_route_map, target)))
            end
            continue
        end
        for route in routes(bucket)
            target = to_match_by(route)
            route_map = (; route_map..., target => _append_unique_wiring_values(get(route_map, target, ()), (route,)))
        end
        for share in shares(bucket)
            target = second_match_by(share)
            share_map = (; share_map..., target => _append_unique_wiring_values(get(share_map, target, ()), (share,)))
        end
    end
    return share_map, route_map
end
