#=
How a `UniquePlanId` answers the hooks of the matching system (Matching.jl) and the registry (Registry/Interfaces.jl,
Registry/LookupKey.jl). Included after both.
=#

# Two ids: the same handle (`same_unique_id`, StructDef.jl). Typed, so two numbered ids fold while compiling.
@inline matcher_equals(a::UniquePlanId{N1}, b::UniquePlanId{N2}) where {N1, N2} = same_unique_id(N1, N2, a, b)
# Untyped (`dynamic_match`): the same answer, compiled once instead of for every pair of ids.
Base.@nospecializeinfer dynamic_equals(@nospecialize(a::UniquePlanId), @nospecialize(b::UniquePlanId)) =
    same_unique_id(typeof(a).parameters[1], typeof(b).parameters[1], a, b)

# A value against a type: the type's `N` names the handle by uuid (a held handle) or by its number in the plan;
# `:dynamic` names none, so no handle matches it by type.
matches_type(id::UniquePlanId, ::Type{UniquePlanId{N}}) where {N} = _matches_plan_number(id, N)
_matches_plan_number(id::UniquePlanId, N::UUID) = origin(id) == N
_matches_plan_number(id::UniquePlanId, N::Int) = plan_number(id) === N
_matches_plan_number(id::UniquePlanId, ::Symbol) = false

matcher_equals(a::UniquePlanId, T::Type{<:UniquePlanId}) = matches_type(a, T)
matcher_equals(T::Type{<:UniquePlanId}, b::UniquePlanId) = matches_type(b, T)
# A merged state (`MatchAnyOf`) holds the ids of the states it merged.
matcher_equals(m::Type{<:MatchAnyOf}, x::Union{UniquePlanId, Type{<:UniquePlanId}}) = _any_matches(m, x)
matcher_equals(x::Union{UniquePlanId, Type{<:UniquePlanId}}, m::Type{<:MatchAnyOf}) = _any_matches(m, x)

# A held id (`UniquePlanId{uuid}`) has its uuid in the type. A dynamic or numbered one has it only in the value: made
# again from a value (`make_held`, `make_dynamic`, `make_numbered`), or a numbered one through its plan's `UniqueKeyMap`.
function reconstruct_matcher(T::Type{UniquePlanId{N}}) where {N}
    is_held_unique_id(T) && return UniquePlanId(N)
    error("Cannot reconstruct `UniquePlanId{$N}` from its type: its uuid is only in the value (a dynamic or numbered id).")
end

# Named after its uuid only, so every form of it (held, dynamic, numbered) gets the same name.
lower_to_lookupkey(id::UniquePlanId) = Symbol(lower_type(UniquePlanId), "_", origin(id))
