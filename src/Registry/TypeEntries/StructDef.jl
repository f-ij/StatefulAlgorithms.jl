"""
Abstract supertype for registry implementations.

Registries provide a static, type-driven name/lookup layer used by the StatefulAlgorithms
system. The primary implementation is `NameSpaceRegistry`, which supports scoped
values, auto-naming, and multiplier tracking.
"""

###############################
##### REGISTRY TYPE ENTRY #####
###############################
"""
Holds scoped value entries for a specific type T
    S: Entries
    M: Multipliers per entry
    D: Dynamic Entries Type (Dict)
    DL: Dynamic Lookup Type (PreferStrongKeyDict)

I'm not super happy about the name, since it's easy to confuse with the ScopedValueEntries,
    but it's what we have for now.
"""

struct RegistryTypeEntry{T,E}
    entries::E   # isbits(x) == true, 
    multipliers::Vector{Float64}
    dynamic_lookup::Dict{Any,Int} # Map from object to (location, index)
end

function RegistryTypeEntry(obj::T) where T
    entrytype = contained_type(obj)
    @DebugMode "Creating RegistryTypeEntry for obj: $obj and type: $entrytype"
    return RegistryTypeEntry{entrytype}(nothing, (), Dict{Any,Int}())
end

RegistryTypeEntry{T}() where {T} = RegistryTypeEntry{T,Tuple{}}((), Float64[], Dict{Any,Int}())
RegistryTypeEntry{T}(entries::E, multipliers, lookup) where {T,E,} = RegistryTypeEntry{T,E}(entries, multipliers, lookup)
RegistryTypeEntry(rte::RegistryTypeEntry{T}, entries) where T = RegistryTypeEntry{T, typeof(getentries(rte))}(entries, get_multipliers(rte), getdynamiclookup(rte))
