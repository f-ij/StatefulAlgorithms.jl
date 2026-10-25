#=
The rewrite modes: what `rewrite_unique_ids` (Rewrite.jl) does to each `UniquePlanId` it meets. The walk itself is the
same for every mode; a mode only says what an id becomes. Each mode is an entry function, the struct it hands to the
walk, and that struct's `rewrite_id` (and `rewrite_type_id`, where an id only a type holds is not kept as it is).

| Mode         | Entry               | Runs when                                   | Id held as a value      | Id only a type holds |
|:-------------|:--------------------|:--------------------------------------------|:------------------------|:---------------------|
| `_StripIds`  | `strip_unique`      | a constructor or DSL block takes its inputs | `UniquePlanId{ValueId}` | kept                 |
| `_NumberIds` | `number_unique_ids` | a plan is built, `resolve(la1, la2, ...)`   | `UniquePlanId{k}`       | `UniquePlanId{k}`    |

In that order: a held id (`UniquePlanId{uuid}`) is stripped at the constructor and numbered when its plan is built.
=#

################################################
##################   STRIP   ###################
################################################

"""
    strip_unique(x) -> x

`x` with every `Unique` handle the user holds as constructors take it: `UniquePlanId{uuid}(uuid)` becomes
`UniquePlanId{ValueId}(uuid)`, the uuid left only in the value. Constructors and DSL blocks call it on their inputs, so
everything they compile sees the same types for every new handle. Ids already stripped or numbered (a nested plan's)
stay as they are; anything without a `Unique` handle is returned as it is.
"""
Base.@nospecializeinfer strip_unique(@nospecialize(x)) = rewrite_unique_ids(x, _StripIds())

"""Strip mode: no state, every held id is stripped the same way."""
struct _StripIds end

# Held (`N` is the uuid): move the uuid out of the type. Stripped or numbered already: leave it.
rewrite_id(::_StripIds, @nospecialize(id::UniquePlanId)) = is_held_unique_id(id) ? UniquePlanId{ValueId}(origin(id)) : id
# An id only a type holds (a handle's type given as an SCRef) keeps its uuid (the default `rewrite_type_id`): without
# a value, it is all there is.

################################################
##################   NUMBER   ##################
################################################

"""
    number_unique_ids(x) -> x, numbered

Numbers the `Unique` handles in `x` (a plan's inputs, or several plans that share a registry): every id becomes
`UniquePlanId{k}(uuid)`, `k` = 1, 2, ... in order of first appearance of its uuid. A nested plan comes numbered on its
own; its ids are numbered again into the new plan's, by uuid. The same code with new handles gives the same numbers,
so the same plan type. Untyped; compiles nothing per uuid.
"""
Base.@nospecializeinfer number_unique_ids(@nospecialize(x)) = rewrite_unique_ids(x, _NumberIds(Dict{UUID, Int}()))

"""Number mode: the numbers given so far, each uuid to its number, in order of first appearance. One per call, so
one plan's numbers start at 1."""
struct _NumberIds
    numbers::Dict{UUID, Int}
end

# Every form (held, stripped, a nested plan's number) is numbered by its uuid: the same handle gets the same `k`
# wherever it appears, a new uuid the next free number.
function rewrite_id(r::_NumberIds, @nospecialize(id::UniquePlanId))
    u = origin(id)
    return UniquePlanId{get!(r.numbers, u, length(r.numbers) + 1)}(u)
end

# An id only a type holds is numbered by the uuid in it; a number or `ValueId` alone does not say which handle it is.
function rewrite_type_id(r::_NumberIds, @nospecialize(T::Type{<:UniquePlanId}))
    u = plan_number(T)
    u isa UUID || error("Cannot number `$T`: only a type holds it, without the value that says which handle it is.")
    return UniquePlanId{get!(r.numbers, u, length(r.numbers) + 1)}
end
