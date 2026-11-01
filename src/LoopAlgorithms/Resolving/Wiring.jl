#=
Step 3 groups and merges wiring with vectors (`_group_wiring_untyped`, `_merge_global_wiring_untyped`), compiled once.
The tuple-recursive `_resolve_and_group_wiring` and `_merge_global_wiring` below build their named tuples by splatting
one key at a time, which compiles once per intermediate named-tuple type; only the typed resolve (Typed.jl) uses them.
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
    own_global = _group_wiring_untyped(registry, getfield(raw_wiring, :global_wiring))
    combined_global = _merge_global_wiring_untyped(inherited_global, own_global)

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
        context_partition(target_ns) isa StatePartition && !(target_ns in owners) && push!(owners, target_ns)
        # Wires attached to this child (`WithWiring`) point at the child itself until now;
        # give them its namespace so they resolve like any route into it.
        bucket = _retarget_owner_routes_untyped(getfield(old_children, i), target_ns)

        # Concrete children receive a single resolved `Wiring`: inherited global
        # wiring for their namespace, occluded by child-scoped routes.
        target_global = _get_wiring(combined_global, target_ns)
        target_child = _get_wiring(_group_wiring_untyped(registry, bucket), target_ns)
        children[i] = _merge_wiring_untyped(target_global, target_child)
    end

    children_ = Tuple(children)
    W = Core.apply_type(PlanWiring, typeof(combined_global), typeof(children_), typeof(own_locals), NoScope, (; returns = (), owners = Tuple(owners)))
    return rebuild_plan(la, Tuple(funcs), new_instance(W, combined_global, children_, own_locals))
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

"""
`_resolve_and_group_wiring` compiled once, for step 3: the routes and shares are resolved on values
(`dynamic_resolve_wiring`, `dynamic_resolve_wiring_pairs`), gathered per target namespace in vectors, and made into
one named tuple at the end. Same keys in the same order: the shares' targets, then the
routes' new ones.
"""
Base.@nospecializeinfer function _group_wiring_untyped(@nospecialize(registry::NameSpaceRegistry), @nospecialize(wiring::Wiring))
    targets = Symbol[]
    routes = Vector{Any}[]
    shares = Vector{Any}[]
    wiring_shares = getfield(wiring, :shares)
    for i in 1:nfields(wiring_shares)
        pairs = dynamic_resolve_wiring_pairs(registry, getfield(wiring_shares, i))
        for k in 1:nfields(pairs)
            target, share = getfield(pairs, k)
            push!(shares[_target_index!(targets, routes, shares, target)], share)
        end
    end
    wiring_routes = getfield(wiring, :routes)
    for i in 1:nfields(wiring_routes)
        target, route = dynamic_resolve_wiring(registry, getfield(wiring_routes, i))
        push!(routes[_target_index!(targets, routes, shares, target)], route)
    end
    values = Any[_new_wiring(Tuple(routes[k]), Tuple(shares[k])) for k in eachindex(targets)]
    return new_named_tuple(targets, values)
end

# The index of `target` in `targets`, added with empty groups if it is not there yet.
function _target_index!(targets::Vector{Symbol}, routes::Vector{Vector{Any}}, shares::Vector{Vector{Any}}, target::Symbol)
    k = findfirst(==(target), targets)
    isnothing(k) || return k
    push!(targets, target); push!(routes, Any[]); push!(shares, Any[])
    return length(targets)
end

"""`_merge_global_wiring` compiled once, for step 3: the keys of `left`, then those of `right` it does not have."""
Base.@nospecializeinfer function _merge_global_wiring_untyped(@nospecialize(left::NamedTuple), @nospecialize(right::NamedTuple))
    nfields(right) == 0 && return left
    targets = Symbol[fieldnames(typeof(left))...]
    for target in fieldnames(typeof(right))
        target::Symbol in targets || push!(targets, target)
    end
    values = Any[_merge_wiring_untyped(_get_wiring(left, target), _get_wiring(right, target)) for target in targets]
    return new_named_tuple(targets, values)
end

"""
`merge_wiring(left, right)` compiled once: the routes of `left` whose aliases none of `right`'s routes has, then
`right`'s routes; the shares of both.
"""
Base.@nospecializeinfer function _merge_wiring_untyped(@nospecialize(left::Wiring), @nospecialize(right::Wiring))
    right_routes = getfield(right, :routes)
    nfields(getfield(left, :routes)) == 0 && nfields(getfield(left, :shares)) == 0 && return right
    right_aliases = Symbol[]
    for r in right_routes
        append!(right_aliases, getaliases(r))
    end
    routes = Any[]
    for r in getfield(left, :routes)
        occluded = false
        for alias in getaliases(r)
            alias::Symbol in right_aliases && (occluded = true)
        end
        occluded || push!(routes, r)
    end
    append!(routes, right_routes)
    return _new_wiring(Tuple(routes), (getfield(left, :shares)..., getfield(right, :shares)...))
end

# `get(grouped, target, Wiring())` for a named tuple of wiring, compiled once.
Base.@nospecializeinfer _get_wiring(@nospecialize(grouped::NamedTuple), target::Symbol) =
    _haskey_untyped(grouped, target) ? getfield(grouped, target) : Wiring()

"""`_retarget_owner_routes` compiled once, for step 3: each route that belongs to the child made with `new_instance`."""
Base.@nospecializeinfer function _retarget_owner_routes_untyped(@nospecialize(bucket::Wiring), target_ns::Symbol)
    old = getfield(bucket, :routes)
    nfields(old) == 0 && return bucket
    new = Vector{Any}(undef, nfields(old))
    for i in eachindex(new)
        r = getfield(old, i)
        if target_match_by(r) === OwnerMatcher
            source = get_source_ref(r)
            R = Core.apply_type(Route, source_match_by(r), target_ns, gettransform(r), getreverse_transform(r), source_fieldnames(r), getaliases(r), typeof(source), Nothing)
            r = new_instance(R, source, nothing)
        end
        new[i] = r
    end
    return _new_wiring(Tuple(new), getfield(bucket, :shares))
end
