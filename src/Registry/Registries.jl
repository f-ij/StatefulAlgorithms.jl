#=
Reading a registry: finding an algorithm, its key, its multiplier, and listing what the registry holds.

A `NameSpaceRegistry` holds one `RegistryTypeEntry` per entry type (`Lin`, a state type, ...), each with its keyed
algorithms in order (`Lin_1`, `Lin_2`, ...). An algorithm is found in two steps: its entry type (`assign_entrytype`,
`find_typeidx`), then its place within that entry: by its matcher for values found by their type or id
(`isstaticallyfindable`: `isbits` values, types, handles), else through the entry's runtime lookup table.
Building a registry is in Builder.jl.
=#

"""
    RegistryLocation(T, idx)

Where an algorithm is in a registry, as a type: entry type `T`, position `idx` within it (`nothing` when not found).
"""
struct RegistryLocation{T, Int} end
RegistryLocation(T, idx) = RegistryLocation{T, idx}()
getentrytype(loc::RegistryLocation{T, idx}) where {T, idx} = T
getidx(loc::RegistryLocation{T, idx}) where {T, idx} = idx

"""The registry's entries, one `RegistryTypeEntry` per entry type, in order."""
getentries(reg::NameSpaceRegistry{T}) where {T} = getfield(reg, :entries)
Base.getindex(reg::NameSpaceRegistry, idx::Int) = getentries(reg)[idx]
Base.length(reg::NameSpaceRegistry) = length(getentries(reg))

###############################################################################
# Entry types
###############################################################################

"""The types of the registry's entries (`RegistryTypeEntry{Lin, ...}`, ...), as a tuple; for a registry or its type."""
@inline typeentry_types(reg::Union{NameSpaceRegistry{T}, Type{NameSpaceRegistry{T}}}) where {T} = tuple(T.parameters...)

"""The registry's entry types (`Lin`, ...) as a tuple type, `Tuple{Lin, ...}`; for a registry or its type."""
@inline entrytypes(reg::Union{NameSpaceRegistry{T}, Type{NameSpaceRegistry{T}}}) where {T} =
    Tuple{map(getentrytype, typeentry_types(reg))...}

"""
    find_typeidx(registry, x) -> index or nothing

The index of the entry that `x` (an algorithm, or a type) belongs to, by its type; for a registry or its type.
"""
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, obj) = _find_typeidx(regt, typeof(obj))
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, typ::Type) = _find_typeidx(regt, typ)
@inline find_typeidx(reg::NameSpaceRegistry, obj) = find_typeidx(typeof(reg), obj)
# `_find_typeidx` is generated: GeneratedCode/Registry.jl.

"""
    get_type_entries(registry, x) -> RegistryTypeEntry

The entry of `registry` that `x` (an algorithm, or a type) belongs to (`assign_entrytype`). Errors when the registry
has no such entry: the algorithm is not registered (for example a `Route` or `Share` naming an algorithm that is not
in the plan).
"""
function get_type_entries(reg::NameSpaceRegistry, obj)
    assigned_t = assign_entrytype(obj)
    idx = find_typeidx(reg, assigned_t)
    if isnothing(idx)
        error("Unknown algo/type referenced in registry lookup, for registry: $reg.\n" *
              "Requested type: $assigned_t\n" *
              "Requested value: $obj\n" *
              "Available entry types: $(map(getentrytype, typeentry_types(reg)))\n" *
              "If this came from a Share or Route, the referenced algo/type is not registered." )
    end
    return getentries(reg)[idx]
end

###############################################################################
# Finding an algorithm
###############################################################################

"""
    reg[algo] -> keyed algo

The algorithm `algo` as `reg` stores it (keyed, `Lin_1`); errors when it is not in `reg`. Found by its matcher, or
through the runtime lookup table for values that are not `isstaticallyfindable`.
"""
@inline function Base.getindex(reg::NameSpaceRegistry{T}, obj) where {T}
    if isstaticallyfindable(obj)
        return static_get(reg, obj)
    else
        entry = dynamic_get(reg, obj)
        isnothing(entry) && error("No matching entry found for value: $obj in registry: $reg")
        return entry
    end
end

"""`reg[algo]`, or `default` when `algo` is not in `reg`."""
@inline function Base.get(reg::NameSpaceRegistry, obj, default = nothing)
    if isstaticallyfindable(obj)
        try
            return static_get(reg, obj)
        catch e
            return default
        end
    else
        try
            return dynamic_get(reg, obj)
        catch e
            return default
        end
    end
end

"""Whether `val` is in `reg`."""
@inline function Base.in(val, reg::NameSpaceRegistry)
    found_scoped_value = @inline get(reg, val, nothing)
    return !isnothing(found_scoped_value)
end

"""The algorithm `v` as `reg` stores it, found by its matcher (`findfirst_match`); for `isstaticallyfindable` values."""
function static_get(reg::NameSpaceRegistry, v::V) where {V}
    entries = get_type_entries(reg, v)
    idx = findfirst_match(entries, v)
    if isnothing(idx)
        return static_get(entries, v)
    end
    return entries[idx]
end

"""The algorithm `val` as `reg` stores it, or `nothing`, found by its matcher only."""
@inline function static_get_match(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    @DebugMode "Static get match for value: $val in entries: $entries"
    idx = static_findfirst_match(entries, val)
    if isnothing(idx)
        return nothing
    end
    return getalgos(entries)[idx]
end

"""Where `val` is in `reg`, found by its matcher, as a `RegistryLocation` (index `nothing` when not found)."""
@inline function static_findfirst_match(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    T = getentrytype(entries)
    idx = static_findfirst_match(entries, val)
    if isnothing(idx)
        return RegistryLocation(T, nothing)
    end
    return RegistryLocation(T, idx)
end

"""The algorithm at `location` in `reg`."""
function Base.getindex(reg::NameSpaceRegistry, t::RegistryLocation{T, idx}) where {T, idx}
    if isnothing(T)
        error("No matching entry found for type: (nothing, nothing) in registry")
    end
    type_entries = get_type_entries(reg, T)
    return type_entries[idx]
end

"""The position of `val` within its entry, found through the entry's runtime lookup table (values that are not `isbits`)."""
function dynamic_lookup(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    return dynamic_lookup(entries, val)
end

"""The algorithm `val` as `reg` stores it, found through the runtime lookup table (values that are not `isbits`)."""
function dynamic_get(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    return dynamic_get(entries, val)
end

"""
    get_by_matcher(registry, matcher) -> keyed algo

The first algorithm in `registry` whose `match_by` equals `matcher`; errors when there is none.
"""
@inline function get_by_matcher(reg::NameSpaceRegistry, matcher)
    return _get_by_matcher(matcher, all_algos(reg))
end
@inline function _get_by_matcher(matcher, entries)
    if isempty(entries)
        error("Matcher $matcher not found in registry entries: $entries")
    end
    head = gethead(entries)
    if match_by(head) == matcher
        return head
    end
    return _get_by_matcher(matcher, gettail(entries))
end

"""
    findall(T, registry) -> tuple

All algorithms in `registry` whose algorithm type is a subtype of `T`, as the registry stores them (keyed handles);
a handle matches by the type of the algorithm it wraps.
"""
@inline function Base.findall(::Type{T}, reg::NameSpaceRegistry) where {T}
    return flat_collect_broadcast(entry -> findall(T, entry), getentries(reg))
end

###############################################################################
# Keys
###############################################################################

"""The key of `val` in `reg` (`Lin_1`), or `nothing` when `val` is not in `reg`."""
@inline function Base.getkey(reg::NameSpaceRegistry, val)
    entry = get(reg, val, nothing)
    if isnothing(entry)
        return nothing
    end
    return getkey(entry)
end

"""The key of `val` in `reg`, found by its matcher, or `nothing`."""
@inline function static_findkey(reg::NameSpaceRegistry, val)
    location = @inline static_findfirst_match(reg, val)
    if isnothing(getidx(location))
        return nothing
    else
        return @inline getkey(reg[location])
    end
end

"""The algorithm with key `s` (`reg[:Lin_1]`); errors when there is none."""
@inline Base.getindex(reg::NameSpaceRegistry{T}, s::Symbol) where T = _getsymbolindex(reg, Val(s))
@inline @generated function _getsymbolindex(reg::NameSpaceRegistry{Ty}, v::Val{key}) where {Ty, key}
    T = nothing
    found_idx = nothing
    for entry in typeentry_types(reg)
        fidx = findkeyposition(entry, key)
        if !isnothing(fidx)
            T = getentrytype(entry)
            found_idx = fidx
            break
        end
    end
    if isnothing(T)
        error("No entry with key: $key found in registry: $reg")
    end
    loc = RegistryLocation(T, found_idx)
    return :(getindex(reg, $loc))
end

"""The keys of all algorithms in `reg`, in order; for a registry or its type."""
function all_keys(reg::Union{NameSpaceRegistry, Type{<:NameSpaceRegistry}})
    flat_collect_broadcast(keys, getentries(reg))
end

###############################################################################
# Multipliers
###############################################################################

"""How often `val` runs per root step (its multiplier), found by its matcher; errors when it is not in `reg`."""
function static_get_multiplier(reg::NameSpaceRegistry, val)
    loc = static_findfirst_match(reg, val)
    if isnothing(getidx(loc))
        error("Found other values of type $(getentrytype(loc)), but no match found for value: $val in registry: $reg")
    end
    type_entries = get_type_entries(reg, getentrytype(loc))
    return getmultiplier(type_entries, getidx(loc))
end

"""How often `val` runs per root step (its multiplier); 0 when it is not in `reg`."""
function getmultiplier(reg::NameSpaceRegistry, val)
    entries = get_type_entries(reg, val)
    entry_idx = if isstaticallyfindable(val)
        static_findfirst_match(entries, val)
    else
        dynamic_lookup(entries, val)
    end
    if isnothing(entry_idx)
        return 0
    end
    return getmultiplier(entries, entry_idx)
end

###############################################################################
# Listing
###############################################################################

"""All algorithms in `reg` as the registry stores them (keyed), states first, then in entry order."""
function all_algos(reg::NameSpaceRegistry)
    return flat_collect_broadcast(getalgos, getentries(reg))
end

"""All algorithms in `reg` that have a key, in order; for a registry or its type."""
function all_named_algos(reg::Union{NameSpaceRegistry, Type{<:NameSpaceRegistry}})
    flat_collect_broadcast(getalgos, getentries(reg))
end

"""Iterates over the registry's entries (`RegistryTypeEntry`s), in order."""
function Base.iterate(reg::NameSpaceRegistry, state = 1)
    if state > length(getentries(reg))
        return nothing
    else
        return (reg[state], state + 1)
    end
end

function Base.show(io::IO, reg::NameSpaceRegistry)
    println(io, "NameSpaceRegistry with types: ", map(getentrytype, typeentry_types(reg)))
    if isempty(getentries(reg))
        print(io, "  (empty)")
        return
    end
    limit = get(io, :limit, false)
    for (idx, entry) in enumerate(getentries(reg))
        entry_str = repr(entry; context = IOContext(io, :limit => limit))
        lines = split(entry_str, '\n')
        for (line_idx, line) in enumerate(lines)
            if line_idx == 1
                print(io, "  [", idx, "] ", line)
            else
                print(io, "\n  ", line)
            end
        end
        if idx < length(getentries(reg))
            print(io, "\n")
        end
    end
end
