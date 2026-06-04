"""
Trait for whether a lookup object can use the generated static registry matcher path.

Static cases:
- isbits values
- all type objects
- identifiable wrappers, whose matchers already live in their type/id data
"""
@inline isstaticallyfindable(obj) = isbits(obj)
@inline isstaticallyfindable(::Type) = true
@inline isstaticallyfindable(::AbstractIdentifiableAlgo) = true
