"""
    strip_unique(x) -> x

`x` with every `Unique` handle the user holds as constructors take it: `UniquePlanId{uuid}(uuid)` becomes
`UniquePlanId{ValueId}(uuid)`, the uuid left only in the value. Constructors and DSL blocks call it on their inputs, so
everything they compile sees the same types for every new handle. Ids already stripped or numbered (a nested plan's)
stay as they are; anything without a `Unique` handle is returned as it is.
"""
Base.@nospecializeinfer strip_unique(@nospecialize(x)) = rewrite_unique_ids(x, _StripIds())

struct _StripIds end
rewrite_id(::_StripIds, @nospecialize(id::UniquePlanId)) = is_held_unique_id(id) ? UniquePlanId{ValueId}(origin(id)) : id
# An id only a type holds (a handle's type given as an SCRef) keeps its uuid (the default `rewrite_type_id`): without
# a value, it is all there is.
