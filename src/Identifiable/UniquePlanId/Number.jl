"""
    number_unique_ids(x) -> x, numbered

Numbers the `Unique` handles in `x` (a plan's inputs, or several plans that share a registry): every id becomes
`UniquePlanId{k}(uuid)`, `k` = 1, 2, ... in order of first appearance of its uuid. A nested plan comes numbered on its
own; its ids are numbered again into the new plan's, by uuid. The same code with new handles gives the same numbers,
so the same plan type. Untyped; compiles nothing per uuid.
"""
Base.@nospecializeinfer number_unique_ids(@nospecialize(x)) = rewrite_unique_ids(x, _NumberIds(Dict{UUID, Int}()))

"""The numbers given so far: each uuid to its number, in order of first appearance."""
struct _NumberIds
    numbers::Dict{UUID, Int}
end

function rewrite_id(r::_NumberIds, @nospecialize(id::UniquePlanId))
    u = origin(id)
    return UniquePlanId{get!(r.numbers, u, length(r.numbers) + 1)}(u)
end
# Every holder keeps its id as a value (`list_field_derived_params`): a type alone has nothing to number it by.
rewrite_type_id(::_NumberIds, @nospecialize(T::Type{<:UniquePlanId})) =
    error("Cannot number `$T`: only a type holds it, without the value that says which handle it is.")
