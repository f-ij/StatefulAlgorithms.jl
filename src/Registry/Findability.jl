"""
    isstaticallyfindable(x) -> Bool

Whether `x` is found in a registry by its matcher, worked out while compiling (`static_findfirst_match`): true for
`isbits` values and types; a handle (`IdentifiableAlgo`) when its matcher is (`match_by`). Other values are found
through a registry entry's runtime lookup table (`dynamic_lookup`, `LookupKey`). Decided from the type of `x`.
Extended by: `UniquePlanId` (only a numbered id), Identifiable/UniquePlanId/HookExtensions.jl.
"""
@inline isstaticallyfindable(obj) = isbits(obj)
@inline isstaticallyfindable(::Type) = true
@inline isstaticallyfindable(::AbstractIdentifiableAlgo) = true
# A handle is found from its type when its matcher is (`match_by`).
@inline isstaticallyfindable(h::IdentifiableAlgo) = isstaticallyfindable(match_by(h))
