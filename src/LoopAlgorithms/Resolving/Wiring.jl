#=
URGENT (2026-10-17, from a review; not fixed yet): compile time. `_resolve_and_group_wiring` and `_merge_global_wiring`
build their named tuples by tuple recursion and splatting (`(; combined..., key => value)` in `_append_combined_keys`).
Called from the `@nospecialize` step 3, each call is a runtime dispatch, and besides compiling for each registry and
wiring type they compile one method instance per intermediate named-tuple type. Build `Symbol[]`/`Any[]` vectors and
one `NamedTuple{Tuple(keys)}(Tuple(values))` instead, as `_add_scoped_names` does.
=#

############################################################################################
# 3. Wiring
############################################################################################

"""
Resolve the wiring of a plan tree, and copy into each child that is not a plan the global wiring, inherited or the
node's own, aimed at its namespace. Also records, in the `PlanWiring` type,
the namespaces of the algorithms directly in each node (`owners` of its resets; step 4 adds the returns).

Runs once per plan on the plan as a value (`@nospecialize`, loops instead of closures): this function is compiled once,
and only the wiring helpers it calls compile for the registry and wiring types they get. `_resolve_wiring_typed`
(Typed.jl) is the inferred version.
"""
Base.@nospecializeinfer function _resolve_wiring(@nospecialize(la::AbstractPlan), @nospecialize(registry::NameSpaceRegistry), @nospecialize(inherited_global::NamedTuple))
    raw_wiring = getfield(la, :wiring)
    own_locals = getfield(raw_wiring, :locals)

    # Global wiring is grouped by resolved target namespace once per plan node.
    # Child buckets below receive the relevant global wiring already merged in, so
    # `step!` never has to merge plan-global and child-specific wiring.
    own_global = _resolve_and_group_wiring(registry, getfield(raw_wiring, :global_wiring))
    combined_global = _merge_global_wiring(inherited_global, own_global)

    # Resolve nested plans first. Their own `PlanWiring` then becomes the
    # child-indexed value passed to that child during parent stepping.
    algos = getfield(la, :funcs)
    n = nfields(algos)
    funcs = Vector{Any}(undef, n)
    for i in 1:n
        child = getfield(algos, i)
        funcs[i] = child isa LoopSpec ? _resolve_wiring(child, registry, combined_global) : child
    end

    old_children = getfield(raw_wiring, :child_wiring)
    children = Vector{Any}(undef, n)
    owners = Symbol[]
    for i in 1:n
        child = funcs[i]
        if child isa LoopSpec
            children[i] = getfield(child, :wiring)
            continue
        end
        target_ns = _read_child_namespace(la, i)
        # TODO: `Val(target_ns)` on a run-time name compiles `context_partition(::Val)` once per namespace name (2 names: 2
        # new method instances) and dispatches at run time; `_compute_node_scope_typed` (Typed.jl) does the same. Mark the
        # `::Val` fallback in Context/ContextPartitions.jl `@nospecialize`, or check the `Symbol` directly.
        context_partition(Val(target_ns)) isa NamespacePartition && !(target_ns in owners) && push!(owners, target_ns)
        # Wires attached to this child (`WithWiring`) point at the child itself until now;
        # give them its namespace so they resolve like any route into it.
        bucket = _retarget_owner_routes(getfield(old_children, i), target_ns)

        # Concrete children receive a single resolved `Wiring`: inherited global
        # wiring for their namespace, occluded by child-scoped routes.
        target_global = get(combined_global, target_ns, Wiring())
        target_child = get(_resolve_and_group_wiring(registry, bucket), target_ns, Wiring())
        children[i] = merge_wiring(target_global, target_child)
    end

    children_ = Tuple(children)
    W = Core.apply_type(PlanWiring, typeof(combined_global), typeof(children_), typeof(own_locals), NoScope, (; returns = (), owners = Tuple(owners)))
    return rebuild_plan(la, Tuple(funcs), W(combined_global, children_, own_locals))
end

"""
Return the context name of child `i` of `plan`, which is not a nested plan, read from its `Namespace` type as a value
(`plan_child_namespace` reads the same, inferred).
"""
Base.@nospecializeinfer _read_child_namespace(@nospecialize(plan::AbstractPlan), i::Int) =
    typeof(getfield(getfield(plan, :namespaces), i)).parameters[1]::Symbol

#=
Wiring grouped by target namespace: a named tuple from target namespace to the `Wiring` (routes and
shares) aimed at it, e.g. `(; Reader_1 = Wiring((route,), ()))`. Plan-wide wiring is kept in this
form so each child can take its group by its namespace.
=#

"""
Return a named tuple with the keys of `first_keys` and then those of `second_keys` (each once, in that order), each
mapped to `combine(key)`.
"""
@inline _combine_by_key(combine::C, first_keys::NamedTuple, second_keys::NamedTuple) where {C} =
    _append_combined_keys(combine, _append_combined_keys(combine, (;), propertynames(first_keys)), propertynames(second_keys))

"""Append `key => combine(key)` to `combined` for each of `keys` it does not have yet."""
@inline _append_combined_keys(::C, combined::NamedTuple, ::Tuple{}) where {C} = combined
@inline function _append_combined_keys(combine::C, combined::NamedTuple, keys::Keys) where {C, Keys<:Tuple}
    key = first(keys)
    if key in propertynames(combined)
        return _append_combined_keys(combine, combined, Base.tail(keys))
    end
    return _append_combined_keys(combine, (; combined..., key => combine(key)), Base.tail(keys))
end

"""Resolve a `Wiring` bucket and group it by target namespace."""
function _resolve_and_group_wiring(registry::NameSpaceRegistry, wiring::Wiring)
    share_groups = resolve_options(registry, shares(wiring)...)
    route_groups = resolve_options(registry, routes(wiring)...)
    return _combine_by_key(share_groups, route_groups) do key
        Wiring(get(route_groups, key, ()), get(share_groups, key, ()))
    end
end

"""Merge grouped global wiring, with right-side route aliases occluding left."""
function _merge_global_wiring(left::NamedTuple, right::NamedTuple)
    return _combine_by_key(left, right) do key
        merge_wiring(get(left, key, Wiring()), get(right, key, Wiring()))
    end
end
