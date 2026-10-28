"""
    isstaticallyfindable(x) -> Bool

Whether `x`'s match is decided by its type, while compiling: true for `isbits` values and types; a handle
(`IdentifiableAlgo`) when its matcher is (`match_by`). `match` then compares the type-level parts (`static_id`), else the
values (`==`). Decided from the type of `x`.
Extended by: `UniquePlanId` (only a numbered id), Identifiable/UniquePlanId/HookExtensions.jl.
"""
@inline isstaticallyfindable(obj) = isbits(obj)
@inline isstaticallyfindable(::Type) = true
@inline isstaticallyfindable(::AbstractIdentifiableAlgo) = true
# A handle is found from its type when its matcher is (`match_by`).
@inline isstaticallyfindable(h::IdentifiableAlgo) = isstaticallyfindable(match_by(h))
