"""
Raw loop algorithms match by object identity when passed as values.

This keeps existing wrapper surfaces like `IdentifiableAlgo(loopalgo, :name)`
and routed references from `@context` consistent without introducing any custom
DSL runtime machinery.
"""
@inline function match_by(la::LA) where {LA<:LoopSpec}
    if isbits(la)
        return la
    end
    return objectid(la)
end

"""Loop algorithm types match by their type."""
@inline match_by(t::Type{<:LoopSpec}) = t
