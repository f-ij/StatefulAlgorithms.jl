"""
For a NameSpaceRegistry
Extend registry_entrytype(::Type{T}) to decide which type partition in the registry a type belongs to
    This will decide where an algorithm tries to find it's own match

By convention the registry type entry of an object is set by its type, not the object itself.
"""
registry_entrytype(obj) = nothing
registry_allowmerge(::Type) = false
registry_allowmerge(obj) = registry_allowmerge(obj isa Type ? obj : typeof(obj))

function assign_entrytype(obj)
    entry_t = nothing
    if obj isa Type
        entry_t = registry_entrytype(obj)
    else
        entry_t = registry_entrytype(typeof(obj))
    end
    if isnothing(entry_t)
        if obj isa Type
            entry_t = obj
        else
            entry_t = typeof(obj)
        end
    end
    entry_t = Base.typename(entry_t).wrapper
    return entry_t
end
