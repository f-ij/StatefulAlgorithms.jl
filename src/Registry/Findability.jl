"""
    isstaticallyfindable(x) -> Bool

Whether `x` is found in a registry by its matcher, worked out while compiling (`static_findfirst_match`): true for
`isbits` values, types, and handles (`AbstractIdentifiableAlgo`, whose id is in their type). Other values are found
through a registry entry's runtime lookup table.
"""
@inline isstaticallyfindable(obj) = isbits(obj)
@inline isstaticallyfindable(::Type) = true
@inline isstaticallyfindable(::AbstractIdentifiableAlgo) = true
