#=
The forms a `UniquePlanId` is turned into, and when. Each is one `map_matchers_of_type(UniquePlanId, x, f)` (Matching.jl)
with its own `f`; every type that holds ids rebuilds itself with the new ones.

| Entry                      | Runs when                                                     | An id becomes            |
|:---------------------------|:--------------------------------------------------------------|:-------------------------|
| `strip_unique`             | a constructor or DSL block takes its inputs                   | `UniquePlanId{:dynamic}` |
| `number_unique_ids`        | `resolve(la)`, `resolve(la1, la2, ...)`                       | `UniquePlanId{k}`        |
| `number_by_keymap_dynamic` | a lifetime from outside the plan is given to a process or run | `UniquePlanId{k}` of the plan |

In that order: a held id (`UniquePlanId{uuid}`) is stripped at the constructor and numbered when its plan is resolved. A
value from outside the plan (a process's lifetime) is numbered with the plan's numbers when it is given. An id that only
a type holds (a `Var` of a handle's type) is left as it is.
=#

"""
    strip_unique(x) -> x

`x` with every `Unique` handle the user holds as constructors take it: `UniquePlanId{uuid}(uuid)` becomes
`UniquePlanId{:dynamic}(uuid)`, the uuid left only in the value. Constructors and DSL blocks call it on their inputs, so
everything they compile sees the same types for every new handle. Ids already dynamic or numbered (a nested plan's)
stay as they are; anything without a `Unique` handle is returned as it is.
"""
Base.@nospecializeinfer strip_unique(@nospecialize(x)) = map_matchers_of_type(UniquePlanId, x, strip_held_id)

"""A held id (`N` is the uuid) with the uuid moved out of its type; a dynamic or numbered one as it is."""
strip_held_id(@nospecialize(id::UniquePlanId)) = is_held_unique_id(id) ? make_dynamic(id) : id

"""
    number_unique_ids(x) -> x, numbered

Numbers the `Unique` handles in `x` (a plan's inputs, or several plans that share a registry): every id becomes
`UniquePlanId{k}(uuid)`, `k` = 1, 2, ... in order of first appearance of its uuid. Every form (held, dynamic, a nested
plan's number) is numbered by its uuid, so the same handle gets the same `k` wherever it appears and its ids are
numbered again into the new plan's. The same code with new handles gives the same numbers, so the same plan type.
Untyped; compiles nothing per uuid.
"""
Base.@nospecializeinfer function number_unique_ids(@nospecialize(x))
    numbers = sizehint!(Dict{UUID, Int}(), 16)
    return map_matchers_of_type(UniquePlanId, x, id -> make_numbered(id, get!(numbers, origin(id), length(numbers) + 1)))
end

"""
    number_by_keymap_dynamic(x, keymap) -> x, numbered as the plan numbers its handles

`x`, a value from outside a plan that names the plan's `Unique` handles (a lifetime given to `Process`, `InlineProcess`
or `run`), with every id the plan has numbered as the plan numbered it (`keymap`, the plan's `UniqueKeyMap`): held,
dynamic or numbered elsewhere, it becomes `UniquePlanId{k}`, the form the plan's registry stores. A `Var` in `x` is
then found while compiling instead of by uuid on every read in the loop, and `x`'s type has no uuid, so the loop
compiles once. Ids the plan does not have stay as they are; with no map (`nothing`) `x` is returned as it is. Untyped;
compiles nothing per uuid; used where `x` comes in untyped (the `Process`, `InlineProcess` and plan `run`/`init`
entry points). A typed handle numbers while compiling instead (`number_by_keymap`, NumberByKeymapTyped.jl).
"""
Base.@nospecializeinfer function number_by_keymap_dynamic(@nospecialize(x), @nospecialize(keymap))
    keymap isa UniqueKeyMap || return x
    numbers = Dict{UUID, Int}()
    for pair in typeof(keymap).parameters[1]
        numbers[pair.second] = pair.first
    end
    return map_matchers_of_type(UniquePlanId, x, function (id)
        k = get(numbers, origin(id), nothing)
        return isnothing(k) ? id : make_numbered(id, k)
    end)
end
