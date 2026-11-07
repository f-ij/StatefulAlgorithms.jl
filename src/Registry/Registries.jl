#=
Reading a registry: finding an algorithm, its key, its multiplier, and listing what the registry holds.

A `NameSpaceRegistry` holds one `RegistryTypeEntry` per entry type (`Lin`, a state type, ...), each with its keyed
algorithms in order (`Lin_1`, `Lin_2`, ...). An algorithm is found in two steps: its entry type (`assign_entrytype`,
`find_typeidx`), then its place within that entry, with `match` (`static_findfirst_match`): decided while compiling
when the types decide it, else at run time. The entries' runtime lookup tables are kept but not used (`dynamic_get`).
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
@inline typeentry_types(reg::Union{NameSpaceRegistry{T}, Type{<:NameSpaceRegistry{T}}}) where {T} = tuple(T.parameters...)

# TODO: check whether this is dead: grep finds no callers (2026-10-19); check generated code, a call probe and other branches.
"""The registry's entry types (`Lin`, ...) as a tuple type, `Tuple{Lin, ...}`; for a registry or its type."""
@inline entrytypes(reg::Union{NameSpaceRegistry{T}, Type{<:NameSpaceRegistry{T}}}) where {T} =
    Tuple{map(getentrytype, typeentry_types(reg))...}

"""
    find_typeidx(registry, x) -> index or nothing

The index of the entry that `x` (an algorithm, or a type) belongs to, by its type; for a registry or its type.
"""
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, obj) = _find_typeidx(regt, typeof(obj))
@inline find_typeidx(regt::Type{<:NameSpaceRegistry}, typ::Type) = _find_typeidx(regt, typ)
@inline find_typeidx(reg::NameSpaceRegistry, obj) = find_typeidx(typeof(reg), obj)
# `_find_typeidx` is generated: GeneratedCode/Registry/Lookups.jl.

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
    number_held_handle(reg, obj) -> obj

`obj` as `reg` stores it: a `Unique` handle the user holds (`UniquePlanId{uuid}`) numbered by `reg`'s `UniqueKeyMap`
(`numbered_handle`), decided while compiling; anything else, or any `obj` when `reg` has no map, as it is.
"""
@inline number_held_handle(reg::NameSpaceRegistry{E, M}, obj) where {E, M} = numbered_handle(obj, M)

"""
    reg[algo] -> keyed algo

The algorithm `algo` as `reg` stores it (keyed, `Lin_1`); errors when it is not in `reg`. Found with `match`
(`static_findfirst_match`).
"""
@inline function Base.getindex(reg::NameSpaceRegistry{T}, obj) where {T}
    obj = @inline number_held_handle(reg, obj)
    return static_get(reg, obj)
end

"""`reg[algo]`, or `default` when `algo` is not in `reg`: no entry of its type, or no match in that entry. The entry
looks it up by its matcher (`findfirst_match`)."""
@inline function Base.get(reg::NameSpaceRegistry, obj, default = nothing)
    obj = @inline number_held_handle(reg, obj)
    typeidx = find_typeidx(reg, assign_entrytype(obj))
    isnothing(typeidx) && return default
    entry = getentries(reg)[typeidx]
    idx = findfirst_match(entry, obj)
    return isnothing(idx) ? default : getalgos(entry)[idx]
end

"""Whether `val` is in `reg`."""
@inline function Base.in(val, reg::NameSpaceRegistry)
    found_scoped_value = @inline get(reg, val, nothing)
    return !isnothing(found_scoped_value)
end

"""The algorithm `v` as `reg` stores it, found by its matcher (`findfirst_match`)."""
function static_get(reg::NameSpaceRegistry, v::V) where {V}
    entry = get_type_entries(reg, v)
    idx = findfirst_match(entry, v)
    if isnothing(idx)
        return static_get(entry, v)
    end
    return entry[idx]
end

"""The algorithm `val` as `reg` stores it, or `nothing`, found by its matcher only."""
@inline function static_get_match(reg::NameSpaceRegistry, val)
    entry = get_type_entries(reg, val)
    idx = static_findfirst_match(entry, val)
    if isnothing(idx)
        return nothing
    end
    return getalgos(entry)[idx]
end

"""Where `val` is in `reg`, found by its matcher, as a `RegistryLocation` (index `nothing` when not found)."""
@inline function static_findfirst_match(reg::NameSpaceRegistry, val)
    entry = get_type_entries(reg, val)
    T = getentrytype(entry)
    idx = static_findfirst_match(entry, val)
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
    entry = get_type_entries(reg, T)
    return entry[idx]
end

# Kept for now, although no lookup uses them (see `dynamic_lookup` of an entry).
"""The position of `val` within its entry, found through the entry's runtime lookup table (values that are not `isbits`)."""
function dynamic_lookup(reg::NameSpaceRegistry, val)
    entry = get_type_entries(reg, val)
    return dynamic_lookup(entry, val)
end

"""The algorithm `val` as `reg` stores it, found through the runtime lookup table (values that are not `isbits`)."""
function dynamic_get(reg::NameSpaceRegistry, val)
    entry = get_type_entries(reg, val)
    return dynamic_get(entry, val)
end

"""
    findfirst_by_matcher(registry, matcher) -> keyed algo or nothing

The first algorithm in `registry` that the matcher value `matcher` matches (`match`, on values), or `nothing`. A
recursion over the algorithms (a tuple of different types), so a match decided by the types (a numbered `UniquePlanId`,
a matcher without fields) is folded while compiling.
"""
@inline findfirst_by_matcher(reg::NameSpaceRegistry, matcher) = _findfirst_by_matcher(matcher, all_algos(reg))
@inline function _findfirst_by_matcher(matcher, algos)
    isempty(algos) && return nothing
    head = gethead(algos)
    match(matcher, head) && return head
    return _findfirst_by_matcher(matcher, gettail(algos))
end

"""
    get_by_matcher(registry, matcher) -> keyed algo

`findfirst_by_matcher`, erroring when there is none.
"""
@inline function get_by_matcher(reg::NameSpaceRegistry, matcher)
    found = findfirst_by_matcher(reg, matcher)
    isnothing(found) && error("Matcher $matcher not found in the algorithms of the registry: $(all_keys(reg))")
    return found
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
# Finding on values
###############################################################################
#=
The lookups above are decided while compiling: in a plan's loop, or a function of the user's, `reg[algo]` folds to the
algorithm's place in the registry. `resolve` looks up each route's and share's endpoints once, so it uses the versions
below instead: they walk the registry as a value (`getfield`, plain loops) and compare with `dynamic_match`, so they are
compiled once, not once per registry type. They do not number a held `Unique` handle (`number_held_handle`): `resolve`
looks up in its plan's registry before it has a `UniqueKeyMap`, with handles the plan numbered already.
=#

"""
    dynamic_findkey(reg, obj) -> key or nothing

`getkey(reg, obj)` on values: the first entry whose entry type `obj` belongs to (`assign_entrytype`, as `find_typeidx`),
and in it the first algorithm `obj` matches (`dynamic_match`). `nothing` when there is none, or when `obj` cannot be
compared (`getkey` catches the same errors).
"""
Base.@nospecializeinfer function dynamic_findkey(@nospecialize(reg::NameSpaceRegistry), @nospecialize(obj))
    T = assign_entrytype(obj)
    entries = getfield(reg, :entries)
    for i in 1:nfields(entries)
        entry = getfield(entries, i)
        T <: getentrytype(entry) || continue
        algos = getfield(entry, :algos)
        for j in 1:nfields(algos)
            algo = getfield(algos, j)
            found = try
                dynamic_match(obj, algo)
            catch
                return nothing
            end
            found && return getkey(algo)
        end
        return nothing
    end
    return nothing
end

"""
    dynamic_findfirst_algotype(T, reg) -> keyed algo or nothing

`first(findall(T, reg))` on values: the first algorithm in `reg` (entries in order) whose algorithm type is a subtype
of `T` (`_matches_algotype`), or `nothing`.
"""
Base.@nospecializeinfer function dynamic_findfirst_algotype(@nospecialize(T::Type), @nospecialize(reg::NameSpaceRegistry))
    entries = getfield(reg, :entries)
    for i in 1:nfields(entries)
        algos = getfield(getfield(entries, i), :algos)
        for j in 1:nfields(algos)
            algo = getfield(algos, j)
            _matches_algotype(typeof(algo), T) && return algo
        end
    end
    return nothing
end

"""
    dynamic_findfirst_matcher(matcher, reg) -> keyed algo or nothing

`findfirst_by_matcher` untyped: the first algorithm in `reg` (as `all_algos` lists them) that the matcher value
`matcher` matches (`dynamic_match`), or `nothing`. Compiled once, not once per registry and matcher.
"""
Base.@nospecializeinfer function dynamic_findfirst_matcher(@nospecialize(matcher), @nospecialize(reg::NameSpaceRegistry))
    entries = getfield(reg, :entries)
    for i in 1:nfields(entries)
        algos = getfield(getfield(entries, i), :algos)
        for j in 1:nfields(algos)
            algo = getfield(algos, j)
            dynamic_match(matcher, algo) && return algo
        end
    end
    return nothing
end

###############################################################################
# Multipliers
###############################################################################

"""How often `val` runs per root step (its multiplier), found by its matcher; errors when it is not in `reg`."""
function static_get_multiplier(reg::NameSpaceRegistry, val)
    val = @inline number_held_handle(reg, val)
    loc = static_findfirst_match(reg, val)
    if isnothing(getidx(loc))
        error("Found other values of type $(getentrytype(loc)), but no match found for value: $val in registry: $reg")
    end
    entry = get_type_entries(reg, getentrytype(loc))
    return getmultiplier(entry, getidx(loc))
end

"""How often `val` runs per root step (its multiplier); 0 when it is not in `reg`."""
function getmultiplier(reg::NameSpaceRegistry, val)
    val = @inline number_held_handle(reg, val)
    entry = get_type_entries(reg, val)
    entry_idx = static_findfirst_match(entry, val)
    if isnothing(entry_idx)
        return 0
    end
    return getmultiplier(entry, entry_idx)
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
