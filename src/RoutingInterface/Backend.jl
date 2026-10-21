#########################################
######## ROUTING RESOLUTION HELPERS #####
#########################################

"""Return the routes carried by a `Wiring` value."""
routes(w::Wiring) = getfield(w, :routes)

"""Return the shares carried by a `Wiring` value."""
shares(w::Wiring) = getfield(w, :shares)

"""Return the demanded field names carried by a return-demand marker."""
@inline demanded_names(::ReturnDemand{Names}) where {Names} = Names

"""Raw wiring has no owner-runtime return demand attached."""
@inline return_demand(::Wiring) = ReturnDemand{()}()

"""Return the wiring bucket or nested plan wiring of the view's current node."""
@inline current_wiring(pwv::PlanWiringView) = getfield(pwv, :wiring)

"""Return a child view holding the child's wiring subtree (same root type), running in the current node's scope."""
@inline function child_wiring_view(pwv::PlanWiringView{Root,W}, ::Val{idx}) where {Root,W<:PlanWiring,idx}
    child = getfield(child_wiring(current_wiring(pwv)), idx)
    return PlanWiringView{Root,typeof(child),W}(child)
end

"""The routes at the current plan node."""
@inline routes(pwv::PlanWiringView) = @inline routes(current_wiring(pwv))


"""Forward share access through the current plan-wiring view path."""
@inline shares(pwv::PlanWiringView) = shares(@inline current_wiring(pwv))

"""Return whether a concrete route/share set is empty from its tuple types."""
Base.isempty(::Wiring{Routes, Shares}) where {Routes<:Tuple, Shares<:Tuple} =
    fieldcount(Routes) == 0 && fieldcount(Shares) == 0

"""Return whether a plan-wiring view's current bucket carries no routes or shares."""
@inline Base.isempty(pwv::PlanWiringView) = isempty(@inline current_wiring(pwv))

"""Return the route tuple type stored by a `Wiring` type."""
routes_type(::Type{<:Wiring{Routes}}) where {Routes} = Routes

"""Return the share tuple type stored by a `Wiring` type."""
shares_type(::Type{<:Wiring{Routes, Shares}}) where {Routes, Shares} = Shares

"""Return the concrete tuple element types for a tuple type."""
_tuple_field_types(::Type{Tuple{}}) = ()
_tuple_field_types(::Type{T}) where {T<:Tuple} = tuple(T.parameters...)

#= These run while generating code (`return_demand`), once per plan: `@nospecialize` compiles them once instead. =#
"""Flatten route types from a wiring tree type."""
_route_types_from_wiring_type(@nospecialize(W::Type{<:Wiring})) = _tuple_field_types(routes_type(W))
function _route_types_from_wiring_type(@nospecialize(W::Type{<:PlanWiring}))
    GlobalWiring, ChildWiring = W.parameters[1], W.parameters[2]
    global_routes = _route_types_from_grouped_wiring_type(GlobalWiring)
    child_routes = _route_types_from_child_wiring_type(ChildWiring)
    return (global_routes..., child_routes...)
end

"""Flatten route types from target-namespace-grouped global wiring."""
function _route_types_from_grouped_wiring_type(@nospecialize(Grouped::Type{<:NamedTuple}))
    names = fieldnames(Grouped)
    routes = ()
    for name in names
        routes = (routes..., _route_types_from_wiring_type(fieldtype(Grouped, name))...)
    end
    return routes
end

"""Flatten route types from child-indexed wiring."""
function _route_types_from_child_wiring_type(@nospecialize(Children::Type{<:Tuple}))
    routes = ()
    for i in 1:fieldcount(Children)
        routes = (routes..., _route_types_from_wiring_type(fieldtype(Children, i))...)
    end
    return routes
end

"""Append a route's source field name to the demanded names, if it is not there yet."""
_append_route_demand_names(names::Tuple, name::Symbol) = name in names ? names : (names..., name)
function _append_route_demand_names(names::Tuple, route_varnames::Tuple)
    merged = names
    for name in route_varnames
        merged = _append_route_demand_names(merged, name)
    end
    return merged
end

"""Compute demanded owner-runtime return names from the full plan wiring type."""
function _return_demand_names(@nospecialize(W::Type{<:PlanWiring}), owner::Symbol)
    names = ()
    for route_type in _route_types_from_wiring_type(W)
        source_namespace(route_type) === owner || continue
        for route_name in source_fieldnames(route_type)
            names = _append_route_demand_names(names, route_name)
        end
    end
    return names
end

"""Compute demanded owner-runtime return names from the full plan-wiring view."""
@inline @generated function return_demand(::PlanWiringView{Root,W}, ::Namespace{Name}) where {Root<:PlanWiring,W,Name}
    names = _return_demand_names(Root, Name)
    return :(ReturnDemand{$names}())
end

"""Return the concrete tuple element types for a wiring tuple type."""
_wiring_tuple_types(::Type{Tuple{}}) = ()
_wiring_tuple_types(::Type{T}) where {T<:Tuple} = tuple(T.parameters...)

"""Return whether two tuples of symbols overlap."""
_has_symbol_overlap(::Tuple{}, right::Tuple) = false
_has_symbol_overlap(left::Tuple, right::Tuple) = first(left) in right || _has_symbol_overlap(Base.tail(left), right)

"""Collect route aliases from a tuple of route types."""
_route_aliases(::Tuple{}) = ()
_route_aliases(route_types::Tuple) = (getaliases(first(route_types))..., _route_aliases(Base.tail(route_types))...)

"""
Merge two resolved wiring sets using type-level route alias occlusion.

Routes in `right` replace routes from `left` when any local alias overlaps.
Shares are concatenated because they do not bind local variable aliases.
"""
@generated function merge_wiring(left::L, right::R) where {L<:Wiring, R<:Wiring}
    left_routes = _wiring_tuple_types(routes_type(L))
    right_routes = _wiring_tuple_types(routes_type(R))
    left_shares = _wiring_tuple_types(shares_type(L))
    right_shares = _wiring_tuple_types(shares_type(R))

    # Route aliases are the collision key. The right bucket is the more
    # specific child bucket, so it suppresses inherited routes with the same
    # alias entirely at generated-code time.
    right_aliases = _route_aliases(right_routes)
    kept_left_routes = filter(route -> !_has_symbol_overlap(getaliases(route), right_aliases), left_routes)

    # Resolved route/share types have empty constructors, so the generated body
    # recreates the merged wiring from type data without touching field values.
    route_expr = Expr(:tuple, (:( $route() ) for route in (kept_left_routes..., right_routes...))...)
    share_expr = Expr(:tuple, (:( $share() ) for share in (left_shares..., right_shares...))...)
    return :(Wiring($route_expr, $share_expr))
end

"""Treat missing wiring as empty when merging."""
@inline merge_wiring(left::Wiring, ::Nothing) = left

"""Treat missing wiring as empty when merging."""
@inline merge_wiring(::Nothing, right::Wiring) = right

"""Merge two missing wiring buckets into an empty `Wiring`."""
@inline merge_wiring(::Nothing, ::Nothing) = Wiring()

@noinline function _route_target_lookup_error(matcher, reg::NameSpaceRegistry, role::String, err)
    error("Error finding $role of wiring: $(matcher)\n in registry: $(reg). Original error: $(err)")
end
