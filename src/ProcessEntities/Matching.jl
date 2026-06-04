"""
Process entities match by value if a value is given.
"""
@inline function match_by(pe::ProcessEntity)
    if isbits(pe)
        return pe
    else
        return ObjectIDMatcher(pe)
    end
end

"""
Process entity types match by their type.
"""
match_by(t::Type{<:ProcessEntity}) = t
