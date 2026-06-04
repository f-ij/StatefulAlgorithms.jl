################################################
##################  SHARES  ####################
################################################

"""Return the first unresolved share endpoint reference."""
get_firstalgo(s::Share) = getfield(s, :a1)

"""Return the second unresolved share endpoint reference."""
get_secondalgo(s::Share) = getfield(s, :a2)

"""Return the first share endpoint matcher identity or resolved name."""
first_match_by(::Union{Share{from}, Type{<:Share{from}}}) where {from} = from

"""Return the second share endpoint matcher identity or resolved name."""
second_match_by(::Union{Share{from, to}, Type{<:Share{from, to}}}) where {from, to} = to

"""Return whether the share is directional."""
is_directional(::Union{Share{from, to, directional}, Type{<:Share{from, to, directional}}}) where {from, to, directional} = directional

"""Return whether a share has already been resolved to context-name symbols."""
isresolved(s::Union{Share{from, to}, Type{<:Share{from, to}}}) where {from, to} =
    from isa Symbol && to isa Symbol

"""Return the source context name for a resolved share."""
contextname(::Union{Share{from}, Type{<:Share{from}}}) where {from} = from

contextname(::Any) = nothing

"""
Resolve share wiring into target-keyed resolved share values.

Bidirectional shares produce one resolved share for each direction.
"""
function resolve_wiring(reg::NameSpaceRegistry, s::S) where {S<:Share}
    pairs = resolve_wiring_pairs(reg, s)
    return (; pairs...)
end

"""Resolve share wiring into target-keyed pairs for tuple-recursive grouping."""
function resolve_wiring_pairs(reg::NameSpaceRegistry, s::S) where {S<:Share}
    fromname = _resolve_wiring_endpoint(reg, first_match_by(s), get_firstalgo(s), "share origin")
    toname = _resolve_wiring_endpoint(reg, second_match_by(s), get_secondalgo(s), "share target")
    forward = Share{fromname, toname, is_directional(s), Nothing, Nothing}()
    is_directional(s) && return (toname => forward,)
    backward = Share{toname, fromname, is_directional(s), Nothing, Nothing}()
    return (toname => forward, fromname => backward)
end

"""Update unresolved share endpoints against a parent registry."""
function update_keys(s::S, reg::NameSpaceRegistry) where {S<:Share}
    isresolved(s) && return s
    newfirst = _update_wiring_endpoint(get_firstalgo(s), first_match_by(s), reg)
    newsecond = _update_wiring_endpoint(get_secondalgo(s), second_match_by(s), reg)
    return Share(newfirst, newsecond; directional = is_directional(s))
end
