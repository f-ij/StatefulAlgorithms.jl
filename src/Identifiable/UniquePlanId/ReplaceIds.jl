#=
Replacing the `UniquePlanId`s in a value: `replace_unique_ids(x, mode)`, the one function that strips, numbers and maps
them (the modes are in ReplaceModes.jl).

It works in three passes:
1. The type of `x` is walked once (`unique_id_locations`, kept per type): every place in it that holds a `UniquePlanId`
   is noted as a path, a tuple of delayed `getfield`s (`GetField{i}`) and `getindex`es (`GetIndex{i}`).
2. The ids at those places are read from `x` and each is given its replacement by the mode.
3. `x` is built again once, along the noted paths only: each struct on a path is rebuilt with its new fields
   (`rebuild_with_fields`), everything else is kept as it is.
A type without ids, or ids that the mode leaves as they are, give `x` back as it is.

Untyped (`@nospecialize`): a plan rebuilt with new `Unique` handles compiles nothing here.
=#

"""A delayed `getfield(x, i)`: one step of a path into a struct."""
struct GetField{i} end
"""A delayed `getindex(x, i)`: one step of a path into a tuple or named tuple."""
struct GetIndex{i} end

read_step(@nospecialize(x), ::GetField{i}) where {i} = getfield(x, i)
read_step(@nospecialize(x), ::GetIndex{i}) where {i} = x[i]
step_index(::Union{GetField{i}, GetIndex{i}}) where {i} = i

"""
A place in a type that holds a `UniquePlanId`: the `path` to it from the top, and the type found there (`leaftype`): a
`UniquePlanId{N}`, or `Type{X}` for a field that holds a type mentioning one (a handle's type given as an SCRef).
"""
struct UniqueIdLocation
    path::Tuple
    leaftype::Any
end
holds_type(l::UniqueIdLocation) = l.leaftype <: Type

"""
    replace_unique_ids(x, mode) -> x with every `UniquePlanId` in it replaced as `mode` says

An id held as a value becomes `replace_id(mode, id)`; a type holding ids becomes `replace_ids_in_type(T, mode)`.
"""
Base.@nospecializeinfer function replace_unique_ids(@nospecialize(x), mode)
    x isa Type && return replace_ids_in_type(x, mode)
    locations = unique_id_locations(typeof(x))
    isempty(locations) && return x
    old = Any[read_path(x, l.path) for l in locations]
    new = Any[holds_type(l) ? replace_ids_in_type(o, mode) : replace_id(mode, o) for (l, o) in zip(locations, old)]
    all(i -> new[i] === old[i], eachindex(old)) && return x
    return _rebuild_along(x, locations, new, 1, length(locations), 0)
end

"""The value at `path` in `x`."""
Base.@nospecializeinfer function read_path(@nospecialize(x), @nospecialize(path::Tuple))
    for step in path
        x = read_step(x, step)
    end
    return x
end

# `v` rebuilt with the replacements of `locations[lo:hi]`, whose paths all pass through `v` at `depth`. The locations are
# in walk order, so those under one field of `v` are next to each other.
Base.@nospecializeinfer function _rebuild_along(@nospecialize(v), locations::Vector{UniqueIdLocation}, new::Vector{Any}, lo::Int, hi::Int, depth::Int)
    length(locations[lo].path) == depth && return new[lo]
    fields = Any[getfield(v, i) for i in 1:nfields(v)]
    first_of_group = lo
    while first_of_group <= hi
        i = step_index(locations[first_of_group].path[depth + 1])
        last_of_group = first_of_group
        while last_of_group < hi && step_index(locations[last_of_group + 1].path[depth + 1]) == i
            last_of_group += 1
        end
        fields[i] = _rebuild_along(fields[i], locations, new, first_of_group, last_of_group, depth + 1)
        first_of_group = last_of_group + 1
    end
    return rebuild_with_fields(v, fields)
end

################################################
############   WALK OVER THE TYPE   ############
################################################

"""
    unique_id_locations(T) -> Vector{UniqueIdLocation}

Every place in a value of type `T` that holds a `UniquePlanId`, found from `T` alone and kept for the session. A field
declared with an abstract type is not looked into; a mutable value whose type mentions an id is an error, as it cannot
be rebuilt.
"""
Base.@nospecializeinfer function unique_id_locations(@nospecialize(T))
    @lock _UNIQUE_ID_LOCATIONS_LOCK get!(_UNIQUE_ID_LOCATIONS, T) do
        locations = UniqueIdLocation[]
        _collect_locations!(locations, T, ())
        locations
    end
end
const _UNIQUE_ID_LOCATIONS = IdDict{Any, Vector{UniqueIdLocation}}()
const _UNIQUE_ID_LOCATIONS_LOCK = ReentrantLock()

Base.@nospecializeinfer function _collect_locations!(locations::Vector{UniqueIdLocation}, @nospecialize(T), @nospecialize(path::Tuple))
    if T isa DataType && T <: UniquePlanId
        push!(locations, UniqueIdLocation(path, T))
    elseif T isa DataType && T.name === Base.typename(Type)
        type_mentions_unique_ids(T.parameters[1]) && push!(locations, UniqueIdLocation(path, T))
    elseif !isconcretetype(T)
        # declared abstract: what it holds is not known from the type
    elseif ismutabletype(T)
        type_mentions_unique_ids(T) && error("Cannot replace the `Unique` ids inside a mutable value of type $T.")
    else
        step = T <: Union{Tuple, NamedTuple} ? GetIndex : GetField
        for i in 1:fieldcount(T)
            _collect_locations!(locations, fieldtype(T, i), (path..., step{i}()))
        end
    end
    return locations
end

"""Whether `UniquePlanId` appears anywhere in the type `T` itself (its parameters, nested); kept for the session."""
Base.@nospecializeinfer function type_mentions_unique_ids(@nospecialize(T))
    T isa Union && return type_mentions_unique_ids(T.a) || type_mentions_unique_ids(T.b)
    T isa DataType || return false
    T <: UniquePlanId && return true
    @lock _TYPE_MENTIONS_LOCK begin
        cached = get(_TYPE_MENTIONS, T, nothing)
        isnothing(cached) || return cached
        _TYPE_MENTIONS[T] = false   # a type that mentions itself
        found = any(T.parameters) do p
            p isa Type ? type_mentions_unique_ids(p) : !(p isa TypeVar) && type_mentions_unique_ids(typeof(p))
        end
        _TYPE_MENTIONS[T] = found
    end
end
const _TYPE_MENTIONS = IdDict{DataType, Bool}()
const _TYPE_MENTIONS_LOCK = ReentrantLock()

################################################
#############   IDS IN A TYPE   ################
################################################

"""
    replace_ids_in_type(T, mode) -> T with every `UniquePlanId` in it replaced as `mode` says

An id type becomes `replace_type_id(mode, T)`; a value among the parameters is replaced with `replace_unique_ids`.
"""
Base.@nospecializeinfer function replace_ids_in_type(@nospecialize(T), mode)
    T isa Union && return Union{replace_ids_in_type(T.a, mode), replace_ids_in_type(T.b, mode)}
    T isa DataType && type_mentions_unique_ids(T) || return T
    T <: UniquePlanId && return replace_type_id(mode, T)
    params = Any[p isa Type ? replace_ids_in_type(p, mode) : p isa TypeVar ? p : replace_unique_ids(p, mode) for p in T.parameters]
    return Core.apply_type(T.name.wrapper, params...)
end

# An id only a type holds stays as it is, unless the mode says otherwise (`_NumberIds` numbers a held one).
replace_type_id(mode, @nospecialize(T::Type{<:UniquePlanId})) = T
