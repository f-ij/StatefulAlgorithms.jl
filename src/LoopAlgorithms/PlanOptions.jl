"""
The children a plan stores and their child-indexed wiring. `WithWiring` children bring their
wires along by position.
"""
function _split_children_and_wiring(funcs::Tuple, options::Tuple)
    raw = map(_unwrap_with_wiring, funcs)
    return raw, map(_append_withwiring_wires, funcs, _build_child_wiring(raw, options))
end
@inline _unwrap_with_wiring(child) = child
@inline _unwrap_with_wiring(w::WithWiring) = getfield(w, :child)
@inline _append_withwiring_wires(child, bucket) = bucket
@inline _append_withwiring_wires(w::WithWiring, bucket::Wiring) = Wiring((routes(bucket)..., getfield(w, :wires)...), shares(bucket))
_append_withwiring_wires(w::WithWiring, bucket) = error("`WithWiring` can only wire a concrete child, not the nested plan $(getfield(w, :child)).")

"""Point the routes that belong to this child (target namespace `OwnerMatcher`) at its namespace."""
function _retarget_owner_routes(bucket::Wiring, target_ns::Symbol)
    retarget(r) = target_match_by(r) === OwnerMatcher ?
        Route{source_match_by(r), target_ns, gettransform(r), getreverse_transform(r), source_fieldnames(r), getaliases(r), typeof(get_source_ref(r)), Nothing}(get_source_ref(r), nothing) : r
    return Wiring(map(retarget, routes(bucket)), shares(bucket))
end

"""
    _drop_wiring_options(options::Tuple)

The options that are not routes, shares (`AbstractWiring`) or declared locals (`Local`, kept in the plan's wiring),
in their original order: what a plan keeps in its `options` field, next to its `wiring`. For example
`(route, runtime_inputs, redirect)` gives `(runtime_inputs, redirect)`.
"""
@inline function _drop_wiring_options(options::Options) where {Options<:Tuple}
    # Written as recursion instead of `filter` so that the result type stays known for any number of options: Base's
    # `filter` on a tuple of 32 or more elements goes through a `Vector`, which loses the types. The recursion runs on
    # the front of the tuple and decides about the last option on the way back, so its argument only gets shorter.
    kept = _drop_wiring_options(Base.front(options))
    option = last(options)
    return option isa Union{AbstractWiring, Local} ? kept : (kept..., option)
end
@inline _drop_wiring_options(::Tuple{}) = ()

"""The `RootOption`s among `options`, in their original order (written as recursion for the reason in `_drop_wiring_options`)."""
@inline function _root_only(options::Options) where {Options<:Tuple}
    kept = _root_only(Base.front(options))
    option = last(options)
    return option isa RootOption ? (kept..., option) : kept
end
@inline _root_only(::Tuple{}) = ()

"""
    _collect_root_options(la)

The `RootOption`s of every plan in the tree of `la`, in tree order: what `resolve` keeps on the `LoopAlgorithm`. A
nested resolved `LoopAlgorithm` is read through its plan, not through the options it collected, so nothing is counted
twice.
"""
@inline _collect_root_options(plan::AbstractPlan) = (_root_only(getoptions(plan))..., _collect_root_options_children(getalgos(plan))...)
@inline _collect_root_options(la::LoopAlgorithm) = _collect_root_options(getplan(la))
@inline _collect_root_options_children(::Tuple{}) = ()
@inline function _collect_root_options_children(children::Children) where {Children<:Tuple}
    child = first(children)
    head = child isa LoopSpec ? _collect_root_options(child) : ()
    return (head..., _collect_root_options_children(Base.tail(children))...)
end

"""The route/share wiring stored in one plan (plan-wide and per child), as one tuple of `Route`s and `Share`s."""
@inline collect_wiring(plan::AbstractPlan) = _flatten_plan_wiring(global_wiring(getwiring(plan)), child_wiring(getwiring(plan)))
@inline collect_wiring(la::LoopAlgorithm) = collect_wiring(getplan(la))

"""
The route/share wiring of one plan as constructor input that keeps its scope: plan-wide routes and shares as they are,
and those of one child as `LocalPlanOption(child, route)`. `setwiring` (or a constructor) rebuilds the same wiring from
it, which `collect_wiring` alone cannot: it loses which child a route belonged to.

Only for an unresolved plan. After `resolve` the plan-wide wiring is keyed by registry names, holds a share once per
target namespace and, in a nested plan, also the parent plans' wiring; rebuilt from that, shares would double and parent wiring
would be copied into the children.
"""
function collect_scoped_wiring(plan::AbstractPlan)
    wiring = getwiring(plan)
    plan_wide = global_wiring(wiring)
    plan_wide isa Wiring || error("`collect_scoped_wiring` needs an unresolved plan: a resolved plan's wiring cannot be turned back into constructor input. Use the unresolved plan, then call resolve again.")
    scoped = (routes(plan_wide)..., shares(plan_wide)...)
    funcs = getalgos(plan)
    buckets = child_wiring(wiring)
    for i in eachindex(buckets)
        bucket = buckets[i]
        bucket isa Wiring || continue
        for option in (routes(bucket)..., shares(bucket)...)
            scoped = (scoped..., LocalPlanOption(funcs[i], option))
        end
    end
    return scoped
end

"""Rebuild `plan` with other `states` and `options`; every plan type stores `funcs`, its schedule, namespaces, wiring, states and options, in that order."""
function _rebuild_with_states_options(plan::P, states, options) where {P<:AbstractPlan}
    params = P.parameters
    return P.name.wrapper{params[1], params[2], params[3], params[4], params[5], typeof(states), typeof(options)}(
        getfield(plan, 1), getfield(plan, 2), getfield(plan, 3), getfield(plan, 4), states, options)
end

"""Set the states / the options of a plan."""
setstates(plan::AbstractPlan, states) = _rebuild_with_states_options(plan, states, getoptions(plan))
setoptions(plan::AbstractPlan, options) = _rebuild_with_states_options(plan, getstates(plan), options)

"""The route/share wiring of every plan in the tree of `la`, in tree order."""
@inline _collect_tree_wiring(plan::AbstractPlan) = (collect_wiring(plan)..., _collect_tree_wiring_children(getalgos(plan))...)
@inline _collect_tree_wiring(la::LoopAlgorithm) = _collect_tree_wiring(getplan(la))
@inline _collect_tree_wiring_children(::Tuple{}) = ()
@inline function _collect_tree_wiring_children(children::Children) where {Children<:Tuple}
    child = first(children)
    head = child isa LoopSpec ? _collect_tree_wiring(child) : ()
    return (head..., _collect_tree_wiring_children(Base.tail(children))...)
end

"""Collect plan-wide route/share wiring into a `Wiring` value."""
@inline function _build_plan_wiring(options::Options) where {Options<:Tuple}
    routes = typefilter(Route, options)
    shares = typefilter(Share, options)
    return Wiring(routes, shares)
end

"""Return route/share wiring wrapped by a child-scoped plan option."""
@inline _unwrap_local_option(option::LocalPlanOption) = getfield(option, :option)

"""Return the wiring value passed to one child before registry resolution."""
@inline function _select_child_wiring(child, bucket::Wiring)
    return bucket
end

"""Return nested plan wiring for loop-plan children."""
@inline function _select_child_wiring(child::LA, bucket::Wiring) where {LA<:LoopSpec}
    isempty(bucket) || construction_error("Child-scoped wiring ", bucket, " was assigned to nested plan child ", child, ". Attach the route/share to a concrete child inside the nested plan.")
    return getwiring(child)
end

# A named nested plan (see `register_child!` for one): its name plays no part in wiring.
# TODO (TODO.md, "named plans as context slices"): keep it that way, a plan name is read-only.
"""Return nested plan wiring for identifiable loop-plan children."""
@inline function _select_child_wiring(child::IA, bucket::Wiring) where {F<:LoopSpec, IA<:AbstractIdentifiableAlgo{F}}
    isempty(bucket) || construction_error("Child-scoped wiring ", bucket, " was assigned to nested plan child ", child, ". Attach the route/share to a concrete child inside the nested plan.")
    return getwiring(getalgo(child))
end

"""Whether the child-local wiring `option` (a route or share written for one call or algorithm) belongs to `child`."""
Base.@nospecializeinfer function _local_wiring_matches_child(@nospecialize(child), @nospecialize(option::LocalPlanOption))::Bool
    scoped_wiring = _unwrap_local_option(option)
    if scoped_wiring isa Route
        # A route into a function call names the call object itself.
        target_match_by(scoped_wiring) === OwnerMatcher && return match(child, getfield(option, :owner))
        return child_matches_scref(child, target_match_by(scoped_wiring))
    end

    if match(child, getfield(option, :owner))
        return true
    end

    if scoped_wiring isa Share
        return child_matches_scref(child, first_match_by(scoped_wiring)) ||
            child_matches_scref(child, second_match_by(scoped_wiring))
    end
    return false
end

"""
Build the child-indexed wiring tuple stored in `PlanWiring`: for every child position the value that `step!`
receives, a `Wiring(routes, shares)` bucket for a concrete child, or the nested plan's own `PlanWiring`.

Untyped (`@nospecialize`): the result is built from runtime vectors, so its type was never inferable, and a typed
version compiled again for every plan type.
"""
Base.@nospecializeinfer function _build_child_wiring(@nospecialize(funcs::Tuple), @nospecialize(options::Tuple))
    route_buckets = [Any[] for _ in 1:length(funcs)]
    share_buckets = [Any[] for _ in 1:length(funcs)]

    # Group and validate in one pass. A separate validation scan over concrete
    # `Wiring` tuples made large DSL construction spend seconds in inference.
    for option in options
        option isa LocalPlanOption || continue
        scoped_wiring = _unwrap_local_option(option)
        assigned = false
        for i in eachindex(route_buckets)
            _local_wiring_matches_child(funcs[i], option) || continue
            if scoped_wiring isa Route
                push!(route_buckets[i], scoped_wiring)
            elseif scoped_wiring isa Share
                push!(share_buckets[i], scoped_wiring)
            end
            assigned = true
        end
        assigned || construction_error("Child-scoped wiring ", option, " could not be assigned to any child in plan funcs ", funcs, ".")
    end

    child_wiring = Vector{Any}(undef, length(funcs))
    for i in eachindex(child_wiring)
        child_wiring[i] = _select_child_wiring(funcs[i], Wiring(Tuple(route_buckets[i]), Tuple(share_buckets[i])))
    end
    return Tuple(child_wiring)
end

"""`_build_plan_wiring` for construction: the same `Wiring`, built from untyped values."""
Base.@nospecializeinfer function _build_plan_wiring_untyped(@nospecialize(options::Tuple))
    routes = Any[]
    shares = Any[]
    for option in options
        option isa Route && push!(routes, option)
        option isa Share && push!(shares, option)
    end
    return Wiring(Tuple(routes), Tuple(shares))
end

"""`_drop_wiring_options` for construction: the options that are not routes, shares or declared locals, from untyped values."""
Base.@nospecializeinfer function _drop_wiring_options_untyped(@nospecialize(options::Tuple))
    kept = Any[]
    for option in options
        option isa Union{AbstractWiring, Local} || push!(kept, option)
    end
    return Tuple(kept)
end

"""Flatten the raw wiring values stored by a plan for constructor rebuilds."""
@inline function _flatten_plan_wiring(plan_wiring::Wiring, child_wiring::ChildWiring) where {ChildWiring<:Tuple}
    isempty(child_wiring) && return (routes(plan_wiring)..., shares(plan_wiring)...)
    head = getfield(child_wiring, 1)
    head_values = head isa Wiring ? (routes(head)..., shares(head)...) : ()
    return (routes(plan_wiring)..., shares(plan_wiring)..., head_values..., _flatten_plan_wiring(Wiring(), Base.tail(child_wiring))...)
end

"""Append wiring values while preserving first occurrence order."""
function _append_unique_wiring_values(values::Tuple, items::Tuple)
    for item in items
        any(==(item), values) || (values = (values..., item))
    end
    return values
end

"""Flatten grouped `Wiring` buckets into route/share values."""
@inline _flatten_wiring_values(wirings::Tuple{}) = ()
@inline function _flatten_wiring_values(wirings::Wirings) where {Wirings<:Tuple}
    head = first(wirings)
    return (routes(head)..., shares(head)..., _flatten_wiring_values(Base.tail(wirings))...)
end

"""Flatten grouped resolved wiring values for inspection-style callers."""
@inline function _flatten_plan_wiring(grouped::NamedTuple, child_wiring::ChildWiring) where {ChildWiring<:Tuple}
    collected = _flatten_wiring_values(values(grouped))
    isempty(child_wiring) && return collected
    head = getfield(child_wiring, 1)
    if head isa Wiring
        collected = _append_unique_wiring_values(collected, (routes(head)..., shares(head)...))
    end
    return _append_unique_wiring_values(collected, _flatten_plan_wiring((;), Base.tail(child_wiring)))
end
