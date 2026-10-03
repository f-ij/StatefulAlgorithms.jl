"""
For a NameSpaceRegistry
Extend registry_entrytype(::Type{T}) to decide which type partition in the registry a type belongs to
    This will decide where an algorithm tries to find it's own match

By convention the registry type entry of an object is set by its type, not the object itself.
"""
registry_entrytype(obj) = nothing
registry_allowmerge(::Type) = false
registry_allowmerge(obj) = registry_allowmerge(obj isa Type ? obj : typeof(obj))

@inline function _assign_entrytype_of(::Type{T}) where {T}
    entry_t = registry_entrytype(T)
    isnothing(entry_t) && (entry_t = T)
    return Base.typename(entry_t).wrapper
end

# Dispatch on the type parameter so the entry type constant-folds when `obj` is a type.
@inline assign_entrytype(::Type{T}) where {T} = _assign_entrytype_of(T)
@inline assign_entrytype(obj) = _assign_entrytype_of(typeof(obj))
