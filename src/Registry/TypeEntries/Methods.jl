#=
Reading one entry of a registry (`RegistryTypeEntry`): its algorithms, multipliers and keys, and finding an algorithm
in it, by its matcher (`static_findfirst_match`, for `isstaticallyfindable` values) or through its runtime lookup
table (`dynamic_lookup`, for other values).
=#

"""The entry's algorithms (keyed handles), as a tuple; for an entry type, the tuple of their types."""
@inline getentries(rte::RegistryTypeEntry) = getfield(rte, :entries)
@inline getentries(rtetype::Type{<:RegistryTypeEntry{T,S}}) where {T,S} = tuple(S.parameters...)
"""The types of the entry type's algorithms (a `svec`)."""
entry_types(rte::Type{<:RegistryTypeEntry{T,E}}) where {T,E} = E.parameters
"""The entry type (`Lin`) of an entry or of its type."""
gettype(rte::Type{<:RegistryTypeEntry{T}}) where T = T
gettype(rte::RegistryTypeEntry) = gettype(typeof(rte))
"""The number of algorithms in the entry."""
@inline Base.length(te::RegistryTypeEntry) = length(getentries(te))

"""The runtime lookup table of the entry (lookup key => position)."""
@inline getdynamiclookup(rte::RegistryTypeEntry) = getfield(rte, :dynamic_lookup)
"""How often each algorithm of the entry runs per root step, in order."""
@inline getmultipliers(rte::RegistryTypeEntry) = getfield(rte, :multipliers)
"""How often the `idx`-th algorithm of the entry runs per root step."""
@inline getmultiplier(rte::RegistryTypeEntry, idx::Int) = getmultipliers(rte)[idx]

###############################################################################
# Finding an algorithm
###############################################################################

"""
The position of `val` in the entry, found by its matcher (`match_by`), or `nothing`. The type-level part of the matcher
(`static_id`) is what is matched, so a matcher carrying data (`UniquePlanId`) compiles once per type, not per value.

A `Unique` handle the user holds (`UniquePlanId{uuid}`) is found from types in a registry handed to the user, which
stores it with `DoubleMatcher(UniquePlanId{k}, UniquePlanId{uuid})` (`with_held_ids`). The registry `init` and the loop
run with stores only `UniquePlanId{k}`; there it is found through the runtime lookup table, by its uuid.
"""
@inline function static_findfirst_match(rte::RegistryTypeEntry, val)
    id = @inline match_by(val)
    idx = @inline static_findfirst_match(rte, Val(static_id(id)))
    (isnothing(idx) && is_held_unique_id(id)) || return idx
    return dynamic_lookup(rte, val)
end
# `static_findfirst_match(rte, Val(matcher))` is generated: GeneratedCode/Registry.jl.

"""The position of `val` in the entry, found through the runtime lookup table (`dynamic_lookup_key`), or `nothing`."""
dynamic_lookup(rte::RegistryTypeEntry{T}, val) where {T} = get(getdynamiclookup(rte), dynamic_lookup_key(val), nothing)

"""The position of `val` in the entry, or `nothing`: by its matcher when `isstaticallyfindable`, else by lookup."""
@inline findfirst_match(rte::RegistryTypeEntry, val) = isstaticallyfindable(val) ? static_findfirst_match(rte, val) : dynamic_lookup(rte, val)

"""`te[algo]`: the algorithm `algo` as the entry stores it (keyed); errors when it is not there."""
function Base.getindex(te::RegistryTypeEntry, obj)
    if isstaticallyfindable(obj)
        return static_get(te, obj)
    end
    entry = dynamic_get(te, obj)
    isnothing(entry) && error("No matching entry found for value: $obj with matcher $(match_by(obj))\nin RegistryTypeEntry of type $(gettype(te))\nwith entries: $(getentries(te))\nand matchers $(match_by.(getentries(te)))")
    return entry
end

"""`te[idx]`: the `idx`-th algorithm of the entry."""
function Base.getindex(te::RegistryTypeEntry, idx::Int)
    getentries(te)[idx]
end

"""The algorithm `val` as the entry stores it, found by its matcher; errors when it is not there."""
@inline function static_get(rte::RegistryTypeEntry, val::V) where V 
    idx = static_findfirst_match(rte, val)
    if isnothing(idx)
        error("No matching entry found for value: $val with matcher $(match_by(val))\nin RegistryTypeEntry of type $(gettype(rte))\nwith entries: $(getentries(rte))\nand matchers $(match_by.(getentries(rte)))")
    end
    return getentries(rte)[idx]
end

"""The algorithm `val` as the entry stores it, found through the runtime lookup table, or `nothing`."""
@inline function dynamic_get(rte::RegistryTypeEntry{T}, val) where {T}
    idx = dynamic_lookup(rte, val)
    if isnothing(idx)
        return nothing
    end
    return getentries(rte)[idx]
end

"""Iterates over `(algorithm, multiplier)` pairs of the entry, in order."""
function Base.iterate(te::RegistryTypeEntry, state = 1)
    if state > length(te)
        return nothing
    else
        return ((getentries(te)[state], getmultipliers(te)[state]), state + 1)
    end
end

###############################################################################
# Keys
###############################################################################

"""The entry's algorithms (all have a key); for an entry or its type."""
all_named_algos(te::Union{RegistryTypeEntry, Type{<:RegistryTypeEntry}}) = getentries(te)

"""The keys of the entry's algorithms (`Lin_1`, ...), in order; for an entry or its type."""
function all_keys(te::Union{RegistryTypeEntry, Type{<:RegistryTypeEntry}})
    getkey.(getentries(te))
end

"""The keys of the entry's algorithms, as a constant tuple; for an entry or its type."""
@inline @generated function Base.keys(entry::Union{RTE, Type{<:RTE}}) where RTE<:RegistryTypeEntry
    keys = getkey.(getentries(RTE))
    return :($keys)
end

"""The entry with the keys in `changed_names` (`old => new`) replaced."""
function replacecontextkeyss(te::RegistryTypeEntry, changed_names::Dict{Symbol,Symbol})
    ps = pairs(changed_names)
    unrollreplace_splat(te, ps...) do rte, (oldname, newname)
        setcontextkey(rte, newname)
    end
end

"""The position of the algorithm with key `key` in the entry, or `nothing`; for an entry or its type."""
@inline findkey(te::Union{RTE, Type{<:RTE}}, key::Symbol) where RTE <: RegistryTypeEntry = findkey(te, Val(key))
@inline @generated function findkey(te::Union{RTE, Type{<:RTE}}, ::Val{key}) where {RTE <: RegistryTypeEntry, key}
    entries = getentries(RTE)
    idx = findfirst(x -> getkey(x) == key, entries)
    if isnothing(idx)
        return :(nothing)
    else
        return :($idx)
    end
end

"""Whether the entry has an algorithm with key `key`; for an entry or its type."""
@inline Base.haskey(te::Union{RTE, Type{<:RTE}}, key::Symbol) where RTE <: RegistryTypeEntry = !isnothing(findkey(te, key))

@inline _registry_findall_type(::Type{E}) where {E} = E
@inline _registry_findall_type(::Type{<:AbstractIdentifiableAlgo{F}}) where {F} = F
@inline _registry_findall_matches(::Type{E}, ::Type{T}) where {E, T} = _registry_findall_type(E) <: T

@inline _registry_findall_type_entries(::Type{T}, ::Tuple{}) where {T} = ()
@inline function _registry_findall_type_entries(::Type{T}, entries::Tuple) where {T}
    head = first(entries)
    tail_matches = _registry_findall_type_entries(T, Base.tail(entries))
    return _registry_findall_matches(typeof(head), T) ? (head, tail_matches...) : tail_matches
end

"""
    findall(T, entry) -> tuple

The entry's algorithms whose algorithm type is a subtype of `T`, as stored (keyed handles); a handle matches by the
type of the algorithm it wraps.
"""
@inline Base.findall(::Type{T}, te::RegistryTypeEntry) where {T} =
    _registry_findall_type_entries(T, getentries(te))

function Base.show(io::IO, rte::RegistryTypeEntry{T}) where {T}
    println(io, "RegistryTypeEntry for type: $(T)")
    if length(getentries(rte)) == 0
    else
        entries = getentries(rte)
        limit = get(io, :limit, false)
        n = length(entries)
        head = 3
        tail = 2
        if !limit || n <= head + tail + 1
            for (idx, entry) in enumerate(entries)
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
        else
            for idx in 1:head
                entry = entries[idx]
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
            println(io, "\t...")
            for idx in (n - tail + 1):n
                entry = entries[idx]
                println(io, "\t", idx, " \t => ", entry, " x ", getmultiplier(rte,idx))
            end
        end
    end
end
