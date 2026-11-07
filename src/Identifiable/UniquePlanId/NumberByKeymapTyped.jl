#=
`number_by_keymap(x, keymap)`: what `number_by_keymap_dynamic` (ReplaceModes.jl) does, decided while compiling. The typed
handles (`run(ip; lifetime)`, `run(p; lifetime)`, a manager's per-job lifetime) number the lifetime they are given with
it, so the numbered lifetime is inferred and costs no walk at run time.

Why it is a file of its own: it walks the TYPE of `x` (every field type, recursively) and generates the rebuilt value,
where `number_by_keymap_dynamic` asks each value to rebuild itself (`map_matchers_of_type`). That type walk was the old
way every id form was made; it is kept only here, until it is measured against `number_by_keymap_dynamic` (a typed run
given a lifetime with `Unique` handles). Faster by little: this file goes and the handles call
`number_by_keymap_dynamic`. Nothing outside this file uses what it defines but `number_by_keymap`.
=#

"""A delayed `getfield(x, i)`: one step of a path into a struct."""
struct _KeymapGetField{i} end
"""A delayed `getindex(x, i)`: one step of a path into a tuple or named tuple."""
struct _KeymapGetIndex{i} end
_step_index(::Union{_KeymapGetField{i}, _KeymapGetIndex{i}}) where {i} = i

"""
A place in a type that holds a `UniquePlanId`: the `path` to it from the top, and the type found there (`leaftype`): a
`UniquePlanId{N}`, or `Type{X}` for a field that holds a type mentioning one.
"""
struct _KeymapIdLocation
    path::Tuple
    leaftype::Any
end
_holds_type(l::_KeymapIdLocation) = l.leaftype <: Type

"""
Every place in a value of type `T` that holds a `UniquePlanId`, found from `T` alone and kept for the session. A field
declared with an abstract type is not looked into; a mutable value whose type mentions an id is an error, as it cannot
be rebuilt.
"""
Base.@nospecializeinfer function _keymap_id_locations(@nospecialize(T))
    @lock _KEYMAP_ID_LOCATIONS_LOCK get!(_KEYMAP_ID_LOCATIONS, T) do
        locations = _KeymapIdLocation[]
        _collect_keymap_locations!(locations, T, ())
        locations
    end
end
const _KEYMAP_ID_LOCATIONS = IdDict{Any, Vector{_KeymapIdLocation}}()
const _KEYMAP_ID_LOCATIONS_LOCK = ReentrantLock()

Base.@nospecializeinfer function _collect_keymap_locations!(locations::Vector{_KeymapIdLocation}, @nospecialize(T), @nospecialize(path::Tuple))
    if T isa DataType && T <: UniquePlanId
        push!(locations, _KeymapIdLocation(path, T))
    elseif T isa DataType && T.name === Base.typename(Type)
        _type_mentions_unique_ids(T.parameters[1]) && push!(locations, _KeymapIdLocation(path, T))
    elseif !isconcretetype(T)
        # declared abstract: what it holds is not known from the type
    elseif ismutabletype(T)
        _type_mentions_unique_ids(T) && error("Cannot replace the `Unique` ids inside a mutable value of type $T.")
    else
        step = T <: Union{Tuple, NamedTuple} ? _KeymapGetIndex : _KeymapGetField
        for i in 1:fieldcount(T)
            _collect_keymap_locations!(locations, fieldtype(T, i), (path..., step{i}()))
        end
    end
    return locations
end

"""Whether `UniquePlanId` appears anywhere in the type `T` itself (its parameters, nested); kept for the session."""
Base.@nospecializeinfer function _type_mentions_unique_ids(@nospecialize(T))
    T isa Union && return _type_mentions_unique_ids(T.a) || _type_mentions_unique_ids(T.b)
    T isa DataType || return false
    T <: UniquePlanId && return true
    @lock _TYPE_MENTIONS_LOCK begin
        cached = get(_TYPE_MENTIONS, T, nothing)
        isnothing(cached) || return cached
        _TYPE_MENTIONS[T] = false   # a type that mentions itself
        found = any(T.parameters) do p
            p isa Type ? _type_mentions_unique_ids(p) : !(p isa TypeVar) && _type_mentions_unique_ids(typeof(p))
        end
        _TYPE_MENTIONS[T] = found
    end
end
const _TYPE_MENTIONS = IdDict{DataType, Bool}()
const _TYPE_MENTIONS_LOCK = ReentrantLock()

# A held id type numbered from the map (`numbers`, uuid => k); any other id type, or one the map does not have, as it is.
function _keymap_type_id(numbers::Dict{UUID, Int}, @nospecialize(T::Type{<:UniquePlanId}))
    is_held_unique_id(T) || return T
    k = get(numbers, plan_number(T), nothing)
    return isnothing(k) ? T : UniquePlanId{k}
end

# `T` with every held id type in it numbered from the map; a value among the parameters numbered as a value.
Base.@nospecializeinfer function _keymap_numbered_type(@nospecialize(T), numbers::Dict{UUID, Int})
    T isa Union && return Union{_keymap_numbered_type(T.a, numbers), _keymap_numbered_type(T.b, numbers)}
    T isa DataType && _type_mentions_unique_ids(T) || return T
    T <: UniquePlanId && return _keymap_type_id(numbers, T)
    params = Any[p isa Type ? _keymap_numbered_type(p, numbers) : p isa TypeVar ? p :
                 number_by_keymap_dynamic(p, new_instance(Core.apply_type(UniqueKeyMap, Tuple(k => u for (u, k) in numbers)))) for p in T.parameters]
    return Core.apply_type(T.name.wrapper, params...)
end

# The expression that builds `ex` (a value of type `T`) with the ids at `locations[lo:hi]` numbered from the map, worked
# out from `T` alone: each struct on a path gets the type `_keymap_numbered_type` gives, so a parameter a holder works
# out from a field (a handle's id, a route's matchers) is numbered from its own uuid, as the field is. Runs while
# generating code.
function _numbered_expr(@nospecialize(T), ex, locations::Vector{_KeymapIdLocation}, lo::Int, hi::Int, depth::Int, numbers::Dict{UUID, Int})
    if length(locations[lo].path) == depth
        _holds_type(locations[lo]) && return QuoteNode(_keymap_numbered_type(T.parameters[1], numbers))
        NT = _keymap_type_id(numbers, T)
        return NT === T ? ex : :($NT(origin($ex)))
    end
    exprs = Any[:(getfield($ex, $i)) for i in 1:fieldcount(T)]
    first_of_group = lo
    while first_of_group <= hi
        i = _step_index(locations[first_of_group].path[depth + 1])
        last_of_group = first_of_group
        while last_of_group < hi && _step_index(locations[last_of_group + 1].path[depth + 1]) == i
            last_of_group += 1
        end
        exprs[i] = _numbered_expr(fieldtype(T, i), exprs[i], locations, first_of_group, last_of_group, depth + 1, numbers)
        first_of_group = last_of_group + 1
    end
    T <: Tuple && return :(tuple($(exprs...)))
    T <: NamedTuple && return :(NamedTuple{$(T.parameters[1])}(tuple($(exprs...))))
    return Expr(:new, _keymap_numbered_type(T, numbers), exprs...)
end

"""
    number_by_keymap(x, keymap::UniqueKeyMap) -> x, numbered as the plan numbers its handles

What `number_by_keymap_dynamic` does, decided while compiling: the numbered value is built by code generated for
`typeof(x)` and the map's type, so it is inferred and costs no walk at run time. Used by the typed handles
(`run(ip; lifetime)`, `run(p; lifetime)`, a manager's per-job lifetime), whose type has the map. Compiled once per value
type and map, as the handle's own methods are. When an id in `x` is not held (dynamic or numbered elsewhere: its uuid is
only in the value), it numbers at run time (`number_by_keymap_dynamic`), not inferred. With no map (`nothing`) `x` as it
is.
"""
@generated function number_by_keymap(x::X, keymap::K) where {X, K<:UniqueKeyMap}
    numbers = Dict{UUID, Int}()
    for pair in K.parameters[1]
        numbers[pair.second] = pair.first
    end
    # A mutable value with ids in it cannot be rebuilt: `number_by_keymap_dynamic` reports it.
    locations = try _keymap_id_locations(X) catch; return :(number_by_keymap_dynamic(x, keymap)) end
    isempty(locations) && return :x
    all(l -> _holds_type(l) || is_held_unique_id(l.leaftype), locations) || return :(number_by_keymap_dynamic(x, keymap))
    return _numbered_expr(X, :x, locations, 1, length(locations), 0, numbers)
end
@inline number_by_keymap(x, ::Nothing) = x
