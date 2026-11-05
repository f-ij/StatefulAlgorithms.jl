"""
    UniquePlanId{N}(origin::UUID)

The matcher of a `Unique` handle: what makes two otherwise equal algorithms two entries of the registry, each with its
own state.

Why it is split in two: a uuid in a type makes every `Unique(f)` a new type, so the same code built again with new
handles compiled its plan constructor, `resolve`, `init` and the loop again (a `Process` rebuild 251–295 ms, against
4.7–4.8 ms with the split). So the uuid is data, `origin`, drawn by `Unique(f)` and never changed. The type holds `N`,
which says which of three forms the id is in:

| Form | `N` | Made by | When | The type then |
|---|---|---|---|---|
| held | the uuid (`origin`) | `UniquePlanId(origin)`, `make_held`; `Unique(f)` | the user makes the handle | is a key known from its type, as `SimpleId{uuid}` |
| dynamic | `:dynamic` | `DynamicPlanId(origin)`, `make_dynamic`; `strip_unique`, `DynamicUnique(f)` | a constructor or DSL block takes the handle; a DSL block makes its own `@state`; a plan keeps it so until resolved | is the same for every handle: only the value says which it is |
| numbered | `k` = 1, 2, ... | `UniquePlanId{k}(origin)`, `make_numbered`; `number_unique_ids` | a plan is resolved: each new `origin` gets the next number | is the same in every rebuild of the same code |

The registry, the context, `init` and the loop only see numbered ids, which match by their type alone (`==`). From
`resolve` until the plan is run, the registry also carries the plan's `k => uuid` pairs (`UniqueKeyMap`,
UniqueKeyMap.jl), so a held handle is numbered and found from types there too. The uuid is kept so that every form can
be made again from any other, and for the dynamic fallback of `==`.
"""
struct UniquePlanId{N} <: AbstractMatcher{N}
    origin::UUID
end
"""A held id: the uuid in its type too, as `Unique(f)` makes it."""
UniquePlanId(origin::UUID) = UniquePlanId{origin}(origin)

"""
    DynamicPlanId(origin::UUID)

A dynamic id (`UniquePlanId{:dynamic}`): the uuid in its value only, so its type is the same for every handle. As a type,
it names no handle (`matches_type`).
"""
const DynamicPlanId = UniquePlanId{:dynamic}

"""The `N` of a `UniquePlanId` (value or type): its uuid (held), `:dynamic`, or its number in its plan."""
plan_number(::Union{UniquePlanId{N}, Type{UniquePlanId{N}}}) where {N} = N
"""The uuid a `UniquePlanId` was drawn with."""
origin(id::UniquePlanId) = getfield(id, :origin)

"""Whether `id` (a value or type) is the matcher of a `Unique` handle the user holds (`UniquePlanId{uuid}`)."""
is_held_unique_id(id) = false
is_held_unique_id(id::Union{UniquePlanId, Type{<:UniquePlanId}}) = plan_number(id) isa UUID
"""Whether `id` (a value or type) is a dynamic `UniquePlanId` (`UniquePlanId{:dynamic}`)."""
is_dynamic_unique_id(id) = false
is_dynamic_unique_id(id::Union{UniquePlanId, Type{<:UniquePlanId}}) = plan_number(id) === :dynamic
"""Whether `id` (a value or type) is a `UniquePlanId` numbered in its plan (`UniquePlanId{k}`)."""
is_numbered_unique_id(id) = false
is_numbered_unique_id(id::Union{UniquePlanId, Type{<:UniquePlanId}}) = plan_number(id) isa Int

"""`id` in its held form, `UniquePlanId{uuid}`: made again from its uuid."""
make_held(id::UniquePlanId) = UniquePlanId(origin(id))
"""`id` in its dynamic form, `UniquePlanId{:dynamic}`: the uuid left in the value only."""
make_dynamic(id::UniquePlanId) = DynamicPlanId(origin(id))
"""`id` numbered `k` in its plan, `UniquePlanId{k}`."""
make_numbered(id::UniquePlanId, k::Int) = UniquePlanId{k}(origin(id))

"""
    a == b

Whether two ids are the same handle. The static path first: two numbered ids (or two held ones) are told apart by `N`
alone, so the answer is decided from their types while compiling and the uuid is never read. Only when one of them is
dynamic, or the two are in different forms (a held handle asked of a registry without a map), are their uuids
compared, at run time.
"""
@inline Base.:(==)(a::UniquePlanId{N1}, b::UniquePlanId{N2}) where {N1, N2} = same_unique_id(N1, N2, a, b)
# `==` untyped (`dynamic_match`): the same answer, compiled once instead of for every pair of ids.
Base.@nospecializeinfer dynamic_equals(@nospecialize(a::UniquePlanId), @nospecialize(b::UniquePlanId)) =
    same_unique_id(typeof(a).parameters[1], typeof(b).parameters[1], a, b)
# The answer of both, from the ids' forms `N1`, `N2`: constants in `==`, so it folds there; run-time values in `dynamic_equals`.
@inline function same_unique_id(N1, N2, a::UniquePlanId, b::UniquePlanId)
    N1 isa Int && N2 isa Int && return N1 === N2
    N1 isa UUID && N2 isa UUID && return N1 === N2
    return origin(a) == origin(b)
end
# By uuid: the same hash for every form of one handle. Two numbered ids of different plans with the same `k` are `==`
# but hash apart; they never meet, as only one plan's numbered ids are in a registry.
Base.hash(a::UniquePlanId, h::UInt) = hash(origin(a), hash(UniquePlanId, h))
