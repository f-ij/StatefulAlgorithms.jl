registry_allowmerge(::Any, ::Any) = false

@inline registry_allowmerge(sa::IdentifiableAlgo) = registry_allowmerge(getalgo(sa))

@inline _merge_key_compatible(sa::IdentifiableAlgo, other) =
    haskey(sa) && haskey(other) && getkey(sa) == getkey(other)

@inline _merge_inner(other) = other isa AbstractIdentifiableAlgo ? getalgo(other) : other

@inline function registry_allowmerge(sa::IdentifiableAlgo, other)
    _merge_key_compatible(sa, other) || return false
    return registry_allowmerge(getalgo(sa)) || registry_allowmerge(_merge_inner(other))
end

@inline function registry_allowmerge(sa1::IdentifiableAlgo, sa2::IdentifiableAlgo)
    _merge_key_compatible(sa1, sa2) || return false
    return registry_allowmerge(getalgo(sa1)) || registry_allowmerge(getalgo(sa2))
end

@inline function registry_allowmerge(other, sa::IdentifiableAlgo)
    return registry_allowmerge(sa, other)
end

@inline function _merged_identifiable(
    sa::IdentifiableAlgo{F, Id, Aliases, AlgoName, ScopeName},
    merged_algo,
) where {F, Id, Aliases, AlgoName, ScopeName}
    return IdentifiableAlgo{typeof(merged_algo), Id, Aliases, AlgoName, ScopeName}(merged_algo)
end

function Base.merge(sa::IdentifiableAlgo, other)
    registry_allowmerge(sa, other) || error(
        "Cannot merge identifiable entries with incompatible keys or non-mergeable wrapped values: $(sa) and $(other)"
    )
    merged_algo = merge(getalgo(sa), _merge_inner(other))
    return _merged_identifiable(sa, merged_algo)
end

function Base.merge(sa1::IdentifiableAlgo, sa2::IdentifiableAlgo)
    registry_allowmerge(sa1, sa2) || error(
        "Cannot merge identifiable entries with incompatible keys or non-mergeable wrapped values: $(sa1) and $(sa2)"
    )
    merged_algo = merge(getalgo(sa1), getalgo(sa2))
    return _merged_identifiable(sa1, merged_algo)
end

function Base.merge(other, sa::IdentifiableAlgo)
    registry_allowmerge(sa, other) || error(
        "Cannot merge identifiable entries with incompatible keys or non-mergeable wrapped values: $(other) and $(sa)"
    )
    merged_algo = merge(_merge_inner(other), getalgo(sa))
    return _merged_identifiable(sa, merged_algo)
end
