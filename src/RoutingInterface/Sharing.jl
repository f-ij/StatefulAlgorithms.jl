################################################
##################  SHARES  ####################
################################################

"""Return the first unresolved share endpoint reference."""
get_firstalgo(s::Share) = getfield(s, :a1)

"""Return the second unresolved share endpoint reference."""
get_secondalgo(s::Share) = getfield(s, :a2)

"""Return the first share endpoint matcher identity or resolved name."""
first_match_by(::Union{Share{Smatch}, Type{<:Share{Smatch}}}) where {Smatch} = Smatch

"""Return the second share endpoint matcher identity or resolved name."""
second_match_by(::Union{Share{Smatch, Tmatch}, Type{<:Share{Smatch, Tmatch}}}) where {Smatch, Tmatch} = Tmatch

"""Return whether the share is directional."""
is_directional(::Union{Share{Smatch, Tmatch, directional}, Type{<:Share{Smatch, Tmatch, directional}}}) where {Smatch, Tmatch, directional} = directional

"""Return whether a share has already been resolved to context-name symbols."""
isresolved(s::Union{Share{Smatch, Tmatch}, Type{<:Share{Smatch, Tmatch}}}) where {Smatch, Tmatch} =
    Smatch isa Symbol && Tmatch isa Symbol

"""Return the source namespace of a resolved share."""
contextname(::Union{Share{Smatch}, Type{<:Share{Smatch}}}) where {Smatch} = Smatch

contextname(::Any) = nothing

"""
Resolve share wiring into target-namespace-keyed resolved share values.

Bidirectional shares produce one resolved share for each direction.
"""
function resolve_wiring(reg::NameSpaceRegistry, s::S) where {S<:Share}
    pairs = resolve_wiring_pairs(reg, s)
    return (; pairs...)
end

"""Resolve share wiring into target-namespace-keyed pairs for tuple-recursive grouping."""
function resolve_wiring_pairs(reg::NameSpaceRegistry, s::S) where {S<:Share}
    source_ns = resolve_scref(reg, first_match_by(s), get_firstalgo(s), "first share endpoint")
    target_ns = resolve_scref(reg, second_match_by(s), get_secondalgo(s), "second share endpoint")
    forward = Share{source_ns, target_ns, is_directional(s), Nothing, Nothing}()
    is_directional(s) && return (target_ns => forward,)
    backward = Share{target_ns, source_ns, is_directional(s), Nothing, Nothing}()
    return (target_ns => forward, source_ns => backward)
end

"""Update unresolved share endpoints against a parent registry."""
function update_keys(s::S, reg::NameSpaceRegistry) where {S<:Share}
    isresolved(s) && return s
    newfirst = update_scref(reg, first_match_by(s), get_firstalgo(s))
    newsecond = update_scref(reg, second_match_by(s), get_secondalgo(s))
    return Share(newfirst, newsecond; directional = is_directional(s))
end
