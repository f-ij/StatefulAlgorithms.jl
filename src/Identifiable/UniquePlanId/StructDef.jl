"""
    ValueId

The `N` of a `UniquePlanId` whose type does not say which handle it is: only the value does (its `origin`). A
constructor or DSL block gets its inputs so (`strip_unique`), so it compiles once for every new handle. A type
`UniquePlanId{ValueId}` matches no handle by itself (`matches_type`); the value next to it is numbered when the plan is
built (`number_unique_ids`).
"""
struct ValueId end

"""
    UniquePlanId{N}(origin::UUID)

The matcher of a `Unique` handle: what makes two otherwise equal algorithms two entries of the registry, each with its
own state.

Why it is split in two: a uuid in a type makes every `Unique(f)` a new type, so the same code built again with new
handles compiled its plan constructor, `resolve`, `init` and the loop again (a `Process` rebuild 251–295 ms, against
4.7–4.8 ms with the split). So the uuid is data, `origin`, drawn by `Unique(f)` and never changed. The type holds `N`,
which three functions set as the handle moves:

| `N` | Set by | When | The type then |
|---|---|---|---|
| the uuid (`origin`) | `Unique(f)` | the user makes the handle | is a key known from its type, as `SimpleId{uuid}` |
| `ValueId` | `strip_unique` | a constructor or DSL block takes the handle | is the same for every handle |
| `k` = 1, 2, ... | `number_unique_ids` | a plan is built: each new `origin` gets the next number | is the same in every rebuild of the same code |

The registry, the context, `init` and the loop only see form 3. From `resolve` until the plan is run, the registry also
carries the plan's `k => uuid` pairs (`UniqueKeyMap`, UniqueKeyMap.jl), so a handle the user holds (form 1) is found from
types there too.

Two values are the same handle when their `origin`s are equal; a value and a type match as `matches_type` says.
"""
struct UniquePlanId{N} <: AbstractMatcher{N}
    origin::UUID
end
UniquePlanId(origin::UUID) = UniquePlanId{origin}(origin)

"""The `N` of a `UniquePlanId` (value or type): its uuid, `ValueId`, or its number in its plan."""
plan_number(::Union{UniquePlanId{N}, Type{UniquePlanId{N}}}) where {N} = N
"""The uuid a `UniquePlanId` was drawn with."""
origin(id::UniquePlanId) = getfield(id, :origin)

"""Whether `id` is the matcher of a `Unique` handle the user holds (`UniquePlanId{uuid}`)."""
is_held_unique_id(id) = false
is_held_unique_id(id::UniquePlanId) = plan_number(id) isa UUID

Base.:(==)(a::UniquePlanId, b::UniquePlanId) = origin(a) == origin(b)
Base.hash(a::UniquePlanId, h::UInt) = hash(origin(a), hash(UniquePlanId, h))
