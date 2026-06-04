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

"""Return the root plan wiring carried by a plan-wiring view."""
@inline root_wiring(pwv::PlanWiringView) = getfield(pwv, :wiring)

"""Return a child view one level deeper into the same plan-wiring tree."""
@inline child_wiring_view(pwv::PlanWiringView{W,Path,DemandAll}, ::Val{idx}) where {W,Path,DemandAll,idx} =
    PlanWiringView(root_wiring(pwv), Val((Path..., idx)), Val(DemandAll))

"""Return the concrete wiring bucket or nested plan at the current view path."""
@inline @generated function current_wiring(pwv::PlanWiringView{W,Path,DemandAll}) where {W<:PlanWiring,Path,DemandAll}
    expr = :(root_wiring(pwv))
    for idx in Path
        expr = :(getfield(child_wiring($expr), $idx))
    end
    return expr
end

"""Forward route access through the current plan-wiring view path."""
@inline routes(pwv::PlanWiringView) = routes(@inline current_wiring(pwv))

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

"""Flatten route types from a wiring tree type."""
_route_types_from_wiring_type(::Type{<:Wiring{Routes}}) where {Routes} = _tuple_field_types(Routes)
function _route_types_from_wiring_type(::Type{<:PlanWiring{GlobalWiring, ChildWiring}}) where {GlobalWiring, ChildWiring}
    global_routes = _route_types_from_grouped_wiring_type(GlobalWiring)
    child_routes = _route_types_from_child_wiring_type(ChildWiring)
    return (global_routes..., child_routes...)
end

"""Flatten route types from target-grouped global wiring."""
function _route_types_from_grouped_wiring_type(::Type{Grouped}) where {Grouped<:NamedTuple}
    names = fieldnames(Grouped)
    routes = ()
    for name in names
        routes = (routes..., _route_types_from_wiring_type(fieldtype(Grouped, name))...)
    end
    return routes
end

"""Flatten route types from child-indexed wiring."""
function _route_types_from_child_wiring_type(::Type{Children}) where {Children<:Tuple}
    routes = ()
    for i in 1:fieldcount(Children)
        routes = (routes..., _route_types_from_wiring_type(fieldtype(Children, i))...)
    end
    return routes
end

"""Flatten a route source selector into demanded variable names."""
_append_route_demand_names(names::Tuple, name::Symbol) = name in names ? names : (names..., name)
function _append_route_demand_names(names::Tuple, route_varnames::Tuple)
    merged = names
    for name in route_varnames
        merged = _append_route_demand_names(merged, name)
    end
    return merged
end

"""Compute demanded owner-runtime return names from the full plan wiring type."""
function _return_demand_names(::Type{W}, owner::Symbol) where {W<:PlanWiring}
    names = ()
    for route_type in _route_types_from_wiring_type(W)
        get_fromname(route_type) === owner || continue
        for route_name in getvarnames(route_type)
            names = _append_route_demand_names(names, route_name)
        end
    end
    return names
end

"""Compute demanded owner-runtime return names from the full plan-wiring view."""
@inline @generated function return_demand(::PlanWiringView{W,Path,DemandAll}, ::Namespace{Name}) where {W<:PlanWiring,Path,DemandAll,Name}
    DemandAll === true && return :(ReturnDemand{:all}())
    names = _return_demand_names(W, Name)
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
_route_aliases(route_types::Tuple) = (localnames(first(route_types))..., _route_aliases(Base.tail(route_types))...)

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
    kept_left_routes = filter(route -> !_has_symbol_overlap(localnames(route), right_aliases), left_routes)

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

@noinline function _route_missing_algos_error(reg::NameSpaceRegistry, endpoint, role::String)
    available = all_keys(reg)
    available_str = isempty(available) ? "<none>" : join(string.(available), ", ")
    error("Wiring references $role not found in registry.\nRequested: $(endpoint)\nAvailable names: $available_str")
end

"""Return the algorithm type carried by a `TypeMatcher` identity."""
_typematcher_target(::Type{<:TypeMatcher{T}}) where {T} = T

"""Return the value carried by a `ValMatcher` identity."""
_valmatcher_target(::Type{<:ValMatcher{V}}) where {V} = V

"""Return whether a matcher value has the same type-level endpoint identity."""
_matches_endpoint_match(value, endpoint_match) = value isa endpoint_match
_matches_endpoint_match(value, ::Type{<:ValMatcher{V}}) where {V} = value == V || value isa ValMatcher{V}

"""Resolve a type-matched endpoint without invoking unrelated matcher equality."""
function _resolve_type_matched_endpoint(reg::NameSpaceRegistry, endpoint_match::Type{<:TypeMatcher}, role::String)
    matches = findall(_typematcher_target(endpoint_match), reg)
    isempty(matches) && _route_missing_algos_error(reg, endpoint_match, role)
    return getkey(first(matches))
end

"""Resolve a matcher-identified endpoint by comparing registry entry matchers."""
function _resolve_matched_endpoint(reg::NameSpaceRegistry, endpoint_match::Type{<:AbstractMatcher}, role::String)
    for entry in all_algos(reg)
        _matches_endpoint_match(match_by(entry), endpoint_match) && return getkey(entry)
    end
    _route_missing_algos_error(reg, endpoint_match, role)
end

"""Resolve a raw or symbol endpoint into a context-name symbol."""
function _resolve_wiring_endpoint(reg::NameSpaceRegistry, endpoint_match, endpoint, role::String)
    endpoint_match isa Symbol && return endpoint_match

    # Prefer direct endpoint refs while raw wiring still has them. This keeps
    # object-id matches precise and only falls back to the type-level endpoint
    # identity when a resolved or inherited wiring value no longer carries a ref.
    if endpoint isa AbstractIdentifiableAlgo
        endpoint_key = getkey(endpoint)
        if !isnothing(endpoint_key) && endpoint_key != Symbol()
            return endpoint_key
        end
    end
    if !isnothing(endpoint)
        endpoint_key = getkey(reg, endpoint)
        isnothing(endpoint_key) || return endpoint_key
    end
    endpoint_match isa Type && endpoint_match <: TypeMatcher && return _resolve_type_matched_endpoint(reg, endpoint_match, role)
    endpoint_match isa Type && endpoint_match <: AbstractMatcher && return _resolve_matched_endpoint(reg, endpoint_match, role)
    _route_missing_algos_error(reg, endpoint, role)
end

"""Update an endpoint reference when resolved child wiring is inherited."""
function _update_wiring_endpoint(endpoint, endpoint_match, reg::NameSpaceRegistry)
    !isnothing(endpoint) && return update_keys(endpoint, reg)
    endpoint_match isa Symbol && return endpoint_match
    return reg[_resolve_wiring_endpoint(reg, endpoint_match, endpoint, "endpoint")]
end
