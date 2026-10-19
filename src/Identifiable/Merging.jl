"""Merges two handles that may merge (`handles_merge`): their algorithms combined with `merge`, keeping the id, key and reconstructor of `sa1`."""
function Base.merge(sa1::IdentifiableAlgo{F, Id, Aliases, AlgoName, ScopeName, R}, sa2::IdentifiableAlgo) where {F, Id, Aliases, AlgoName, ScopeName, R}
    handles_merge(typeof(sa1), typeof(sa2)) || error("Cannot merge handles with different keys or non-mergeable algorithms: $(sa1) and $(sa2)")
    merged = merge(getalgo(sa1), getalgo(sa2))
    return IdentifiableAlgo{typeof(merged), Id, Aliases, AlgoName, ScopeName, R}(merged, getfield(sa1, :reconstructor))
end
