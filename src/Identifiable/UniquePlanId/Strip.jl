"""
    strip_unique(x) -> x

`x` with every `Unique` handle the user holds as constructors take it: `UniquePlanId{uuid}(uuid)` becomes
`UniquePlanId{ValueId}(uuid)`, the uuid left only in the value. Constructors and DSL blocks call it on their inputs, so
everything they compile sees the same types for every new handle. Ids already stripped or numbered (a nested plan's)
stay as they are; anything without a `Unique` handle is returned as it is.
"""
Base.@nospecializeinfer strip_unique(@nospecialize(x)) = rewrite_unique_ids(x, _StripIds())

"""`strip_unique` on each element of the tuple `xs`."""
Base.@nospecializeinfer function strip_uniques(@nospecialize(xs::Tuple))
    out = Vector{Any}(undef, length(xs))
    for i in eachindex(out)
        out[i] = strip_unique(xs[i])
    end
    return Tuple(out)
end

struct _StripIds end
rewrite_id(::_StripIds, @nospecialize(id::UniquePlanId)) = is_held_unique_id(id) ? UniquePlanId{ValueId}(origin(id)) : id
rewrite_type_id(::_StripIds, @nospecialize(T::Type{<:UniquePlanId})) = plan_number(T) isa UUID ? UniquePlanId{ValueId} : T
