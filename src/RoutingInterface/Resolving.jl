################################################
#################  RESOLVING  ##################
################################################

@inline resolve(reg::NameSpaceRegistry, wiring...) = @inline resolve_options(reg, wiring...)

"""Resolve no wiring into an empty named tuple."""
function resolve_options(reg::R) where {R<:NameSpaceRegistry}
    return (;)
end

"""Append one resolved wiring item to a target-keyed named tuple."""
@inline function _append_resolved_wiring(grouped::NamedTuple, resolved::Pair)
    name = first(resolved)
    item = last(resolved)
    return (; grouped..., name => (get(grouped, name, ())..., item))
end

"""Append resolved wiring pairs while preserving target-key groups."""
@inline _append_resolved_wiring(grouped::NamedTuple, resolved::Tuple{}) = grouped
@inline function _append_resolved_wiring(grouped::NamedTuple, resolved::Resolved) where {Resolved<:Tuple}
    grouped = _append_resolved_wiring(grouped, first(resolved))
    return _append_resolved_wiring(grouped, Base.tail(resolved))
end

"""
Resolve share wiring and group resolved shares by target context name.
"""
function resolve_options(reg::R, shares::Share...) where {R<:NameSpaceRegistry}
    return _resolve_share_options(reg, shares, (;))
end

"""Resolve share wiring with tuple recursion."""
@inline _resolve_share_options(reg::NameSpaceRegistry, shares::Tuple{}, grouped::NamedTuple) = grouped
@inline function _resolve_share_options(reg::R, shares::Shares, grouped::NamedTuple) where {R<:NameSpaceRegistry, Shares<:Tuple}
    grouped = _append_resolved_wiring(grouped, resolve_wiring_pairs(reg, first(shares)))
    return _resolve_share_options(reg, Base.tail(shares), grouped)
end

"""
Resolve route wiring and group resolved routes by target context name.
"""
@inline function resolve_options(reg::R, routes::Route...) where {R<:NameSpaceRegistry}
    return _resolve_route_options(reg, routes, (;))
end

"""Resolve route wiring with tuple recursion."""
@inline _resolve_route_options(reg::NameSpaceRegistry, routes::Tuple{}, grouped::NamedTuple) = grouped
@inline function _resolve_route_options(reg::R, routes::Routes, grouped::NamedTuple) where {R<:NameSpaceRegistry, Routes<:Tuple}
    grouped = _append_resolved_wiring(grouped, resolve_wiring(reg, first(routes)))
    return _resolve_route_options(reg, Base.tail(routes), grouped)
end
