#=
Reading one entry of a registry (`RegistryTypeEntry`): its algorithms, multipliers and keys, and finding an algorithm
in it with `match` (`static_findfirst_match`: decided while compiling when the types decide it, else by `==` at run time).
The runtime lookup table (`dynamic_lookup`) is kept but no lookup uses it.
=#

"""The entry's algorithms (keyed handles), as a tuple; for an entry type, the tuple of their types."""
@inline getalgos(rte::RegistryTypeEntry) = getfield(rte, :algos)
@inline getalgos(rtetype::Type{<:RegistryTypeEntry{T,S}}) where {T,S} = tuple(S.parameters...)
"""The types of the entry type's algorithms (a `svec`)."""
getalgotypes(rte::Type{<:RegistryTypeEntry{T,E}}) where {T,E} = E.parameters
"""The entry type (`Lin`) of an entry or of its type."""
getentrytype(rte::Type{<:RegistryTypeEntry{T}}) where T = T
getentrytype(rte::RegistryTypeEntry) = getentrytype(typeof(rte))

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
The position of `val` in the entry, found with `match` against each of its algorithms, or `nothing`. Decided while
compiling when the types decide it (a numbered `UniquePlanId`, a matcher without fields, a type); else at run time
(a dynamic `UniquePlanId`, or a held one when the registry has no map, by its uuid): see `match`.
"""
@inline static_findfirst_match(rte::RegistryTypeEntry, val) = @inline find_matching_index(@inline(match_by(val)), getalgos(rte), 1)

# One recursion over the entry's algorithms (a tuple of different types), each compared with `match`: unrolled, so each
# step is typed and a match decided by types is folded while compiling.
@inline find_matching_index(m, ::Tuple{}, i::Int) = nothing
@inline function find_matching_index(m, algos::Tuple, i::Int)
    @inline(match(m, first(algos))) && return i
    return @inline find_matching_index(m, Base.tail(algos), i + 1)
end

# The runtime lookup table: kept for now, although no lookup uses it any more (`static_findfirst_match` covers values
# found at run time). The registry still builds the table (`LookupKey`, `write_lookup_table_expr`).
"""The position of `val` in the entry, found through the runtime lookup table (`LookupKey`), or `nothing`."""
dynamic_lookup(rte::RegistryTypeEntry{T}, val) where {T} = get(getdynamiclookup(rte), LookupKey(val), nothing)

"""The position of `val` in the entry, or `nothing` (`static_findfirst_match`)."""
@inline findfirst_match(rte::RegistryTypeEntry, val) = static_findfirst_match(rte, val)

"""`te[algo]`: the algorithm `algo` as the entry stores it (keyed); errors when it is not there."""
Base.getindex(te::RegistryTypeEntry, obj) = static_get(te, obj)

"""`te[idx]`: the `idx`-th algorithm of the entry."""
function Base.getindex(te::RegistryTypeEntry, idx::Int)
    getalgos(te)[idx]
end

"""The algorithm `val` as the entry stores it, found by its matcher; errors when it is not there."""
@inline function static_get(rte::RegistryTypeEntry, val::V) where V 
    idx = static_findfirst_match(rte, val)
    isnothing(idx) && throw_not_in_entry(rte, val)
    return getalgos(rte)[idx]
end

"""Throws the error for `val` not being in the entry: its matcher and the entry's algorithms and their matchers.
Not inlined, so the message is not built into the callers."""
@noinline function throw_not_in_entry(rte::RegistryTypeEntry, val)
    error("No matching algorithm found for value: $val with matcher $(match_by(val))\nin RegistryTypeEntry of type $(getentrytype(rte))\nwith algorithms: $(getalgos(rte))\nand matchers $(match_by.(getalgos(rte)))")
end

"""The algorithm `val` as the entry stores it, found through the runtime lookup table, or `nothing`."""
@inline function dynamic_get(rte::RegistryTypeEntry{T}, val) where {T}
    idx = dynamic_lookup(rte, val)
    if isnothing(idx)
        return nothing
    end
    return getalgos(rte)[idx]
end

###############################################################################
# Keys
###############################################################################

"""The keys of the entry's algorithms (`Lin_1`, ...), in order, as a constant tuple; for an entry or its type."""
@inline @generated function Base.keys(entry::Union{RTE, Type{<:RTE}}) where RTE<:RegistryTypeEntry
    keys = getkey.(getalgos(RTE))
    return :($keys)
end

"""The position of the algorithm with key `key` in the entry, or `nothing`; for an entry or its type."""
@inline findkeyposition(te::Union{RTE, Type{<:RTE}}, key::Symbol) where RTE <: RegistryTypeEntry = findkeyposition(te, Val(key))
@inline @generated function findkeyposition(te::Union{RTE, Type{<:RTE}}, ::Val{key}) where {RTE <: RegistryTypeEntry, key}
    algotypes = getalgos(RTE)
    idx = findfirst(x -> getkey(x) == key, algotypes)
    if isnothing(idx)
        return :(nothing)
    else
        return :($idx)
    end
end

"""The algorithm type of `E`: the type a handle wraps, or `E` itself."""
@inline _unwrap_algotype(::Type{E}) where {E} = E
@inline _unwrap_algotype(::Type{<:AbstractIdentifiableAlgo{F}}) where {F} = F
"""Whether the algorithm type of `E` (`_unwrap_algotype`) is a subtype of `T`."""
@inline _matches_algotype(::Type{E}, ::Type{T}) where {E, T} = _unwrap_algotype(E) <: T

"""The algorithms in `algos` whose algorithm type is a subtype of `T` (`_matches_algotype`), in order."""
@inline _filter_by_algotype(::Type{T}, ::Tuple{}) where {T} = ()
@inline function _filter_by_algotype(::Type{T}, algos::Tuple) where {T}
    head = first(algos)
    tail_matches = _filter_by_algotype(T, Base.tail(algos))
    return _matches_algotype(typeof(head), T) ? (head, tail_matches...) : tail_matches
end

"""
    findall(T, entry) -> tuple

The entry's algorithms whose algorithm type is a subtype of `T`, as stored (keyed handles); a handle matches by the
type of the algorithm it wraps.
"""
@inline Base.findall(::Type{T}, te::RegistryTypeEntry) where {T} =
    _filter_by_algotype(T, getalgos(te))

function Base.show(io::IO, rte::RegistryTypeEntry{T}) where {T}
    println(io, "RegistryTypeEntry for type: $(T)")
    if length(getalgos(rte)) == 0
    else
        algos = getalgos(rte)
        limit = get(io, :limit, false)
        n = length(algos)
        head = 3
        tail = 2
        if !limit || n <= head + tail + 1
            for (idx, algo) in enumerate(algos)
                println(io, "\t", idx, " \t => ", algo, " x ", getmultiplier(rte,idx))
            end
        else
            for idx in 1:head
                algo = algos[idx]
                println(io, "\t", idx, " \t => ", algo, " x ", getmultiplier(rte,idx))
            end
            println(io, "\t...")
            for idx in (n - tail + 1):n
                algo = algos[idx]
                println(io, "\t", idx, " \t => ", algo, " x ", getmultiplier(rte,idx))
            end
        end
    end
end
