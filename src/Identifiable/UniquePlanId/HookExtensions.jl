#=
How a `UniquePlanId` answers the hooks of the matching system (Matching.jl) and the registry (Registry/Interfaces.jl,
Registry/LookupKey.jl). Included after both.
=#

# A value against a type: the type's `N` names the handle by uuid (a held handle) or by its number in the plan;
# `ValueId` names none, so no handle matches it by type.
matches_type(id::UniquePlanId, ::Type{UniquePlanId{N}}) where {N} = _matches_plan_number(id, N)
_matches_plan_number(id::UniquePlanId, N::UUID) = origin(id) == N
_matches_plan_number(id::UniquePlanId, N::Int) = plan_number(id) === N
_matches_plan_number(id::UniquePlanId, ::Type{ValueId}) = false

Base.:(==)(a::UniquePlanId, T::Type{<:UniquePlanId}) = matches_type(a, T)
Base.:(==)(T::Type{<:UniquePlanId}, b::UniquePlanId) = matches_type(b, T)
# A merged state (`MatchAnyOf`) holds the ids of the states it merged.
Base.:(==)(m::Type{<:MatchAnyOf}, x::Union{UniquePlanId, Type{<:UniquePlanId}}) = _any_matches(m, x)
Base.:(==)(x::Union{UniquePlanId, Type{<:UniquePlanId}}, m::Type{<:MatchAnyOf}) = _any_matches(m, x)

# A held id (`UniquePlanId{uuid}`) has its uuid in the type. A stripped or numbered one has it only in the value.
function reconstruct_matcher(::Type{UniquePlanId{N}}) where {N}
    N isa UUID && return UniquePlanId{N}(N)
    error("Cannot reconstruct `UniquePlanId{$N}` from its type: its uuid is only in the value (a stripped or numbered id).")
end

# Found from its type only when numbered: the registry stores numbered ids. A held id (when the registry has no map to
# number it, `number_held_handle`) and a stripped one are found by their uuid in the runtime lookup table (`LookupKey`).
@inline isstaticallyfindable(id::UniquePlanId) = plan_number(id) isa Int

# Named after its uuid only, so every form of it (held, stripped, numbered) gets the same name.
lower_to_lookupkey(id::UniquePlanId) = Symbol(lower_type(UniquePlanId), "_", origin(id))
