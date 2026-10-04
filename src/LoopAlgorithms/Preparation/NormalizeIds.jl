#=
Renaming the random ids of `Unique` handles before `resolve`.

`Unique(f)` puts a random UUID in the handle's type (`SimpleId{uuid}()`), so every re-run of the same user code
gives a plan of a new type, and the whole typed `resolve` compiles again. `resolve` first renames those ids to
`SimpleId{OrdinalId(k)}()`, numbered by first appearance in the plan's type, and then goes through a function
barrier into the typed body. The same shape with new uuids becomes the same type, so the typed body is compiled once.

The renaming runs on type objects and values held as `Any`, with `@nospecialize`, so it does not compile per uuid.
Each renamed id is also stored in the registry's runtime lookup table, so a handle the user still holds (with its
original uuid) is found at runtime when the compile-time match misses.
=#

"""Sequential id that replaces a random `Unique` UUID inside `resolve`."""
struct OrdinalId
    n::Int
end

function _type_has_random_ids(@nospecialize(T), seen::Base.IdSet{Any})
    T isa DataType || return T isa Union ? (_type_has_random_ids(T.a, seen) || _type_has_random_ids(T.b, seen)) : false
    T in seen && return false
    push!(seen, T)
    T <: SimpleId && !isempty(T.parameters) && T.parameters[1] isa UUID && return true
    for p in T.parameters
        _param_has_random_ids(p, seen) && return true
    end
    return false
end

function _param_has_random_ids(@nospecialize(p), seen::Base.IdSet{Any})
    p isa Type && return _type_has_random_ids(p, seen)
    p isa Tuple && return any(x -> _param_has_random_ids(x, seen), p)
    p isa TypeVar && return false
    return _type_has_random_ids(typeof(p), seen)
end

"""Whether `T` contains a `SimpleId` with a random UUID anywhere in its type parameters."""
@generated _has_random_ids(::Type{T}) where {T} = _type_has_random_ids(T, Base.IdSet{Any}())
# Defined after its helpers: a generator only sees methods that exist when it is defined.

"""Renames random ids in types and values; `ids` maps each UUID to its ordinal, in order of first appearance."""
struct _IdRenamer
    ids::Dict{UUID, Int}
    types::IdDict{Any, Any}
end
_IdRenamer() = _IdRenamer(Dict{UUID, Int}(), IdDict{Any, Any}())

_ordinal!(r::_IdRenamer, u::UUID) = get!(r.ids, u, length(r.ids) + 1)

# No closures, `map` or `all` below: a closure capturing a fresh type, or `map` over a fresh tuple type, compiles per uuid.
function _rename_type(r::_IdRenamer, @nospecialize(T))
    T isa Union && return Union{_rename_type(r, T.a), _rename_type(r, T.b)}
    T isa DataType || return T
    isempty(T.parameters) && return T
    cached = get(r.types, T, nothing)
    isnothing(cached) || return cached
    renamed = if T <: SimpleId && T.parameters[1] isa UUID
        SimpleId{OrdinalId(_ordinal!(r, T.parameters[1]))}
    else
        params = T.parameters
        newparams = Vector{Any}(undef, length(params))
        changed = false
        for i in eachindex(newparams)
            newparams[i] = _rename_param(r, params[i])
            changed |= newparams[i] !== params[i]
        end
        changed ? Core.apply_type(T.name.wrapper, newparams...) : T
    end
    r.types[T] = renamed
    return renamed
end

function _rename_param(r::_IdRenamer, @nospecialize(p))
    p isa Type && return _rename_type(r, p)
    p isa TypeVar && return p
    return _rename_value(r, p)
end

"""Rebuild `v` with renamed ids. Throws `_CannotRename` for mutable objects whose type would change."""
function _rename_value(r::_IdRenamer, @nospecialize(v))
    T = typeof(v)
    T2 = _rename_type(r, T)
    T2 === T && return v
    (ismutable(v) || !(T2 isa DataType) || !isconcretetype(T2)) && throw(_CannotRename(T))
    n = fieldcount(T)
    fields = Vector{Any}(undef, n)
    for i in 1:n
        fields[i] = _rename_value(r, getfield(v, i))
    end
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T2, fields, n)
end

struct _CannotRename <: Exception
    type::Any
end

"""
Rename the random ids of `la`. Returns `(renamed, ids)`, or `(la, nothing)` when a mutable object in the plan
would change type; the plan then resolves with its original ids, which is correct but compiles per uuid.
"""
Base.@nospecializeinfer function rename_random_ids(@nospecialize(la))
    r = _IdRenamer()
    renamed = try
        _rename_value(r, la)
    catch e
        e isa _CannotRename || rethrow()
        return la, nothing
    end
    return renamed, r.ids
end

"""Store each original uuid next to its ordinal in the runtime lookup tables of `registry`."""
function register_original_ids!(registry::NameSpaceRegistry, ids::Dict{UUID, Int})
    for rte in getentries(registry)
        lookup = getdynamiclookup(rte)
        for (u, k) in ids
            idx = get(lookup, SimpleId{OrdinalId(k)}(), nothing)
            # Keyed on the UUID value, not on `SimpleId{u}()`: a key of a fresh type compiles `setindex!` per uuid.
            isnothing(idx) || (lookup[u] = idx)
        end
    end
    return registry
end

"""
Function barrier of `resolve` for plans with random ids: rename, resolve the renamed type, keep held handles findable.

`@nospecializeinfer`: the caller knows the concrete random-id type, and plain `@nospecialize` would still infer this
body (and the typed fallback below) for that type, which is the whole compile cost this barrier exists to avoid.
"""
@noinline Base.@nospecializeinfer function _resolve_renamed(@nospecialize(la))
    renamed, ids = rename_random_ids(la)
    isnothing(ids) && return _resolve_typed(la)
    resolved = _resolve_typed(renamed)
    register_original_ids!(getregistry(resolved), ids)
    return resolved
end
