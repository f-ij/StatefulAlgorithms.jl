#=
Normalizing the random ids of `Unique` handles around `resolve`.

`Unique(f)` puts a random UUID in the handle's type (`SimpleId{uuid}()`), so every re-run of the same user code
gives a plan of a new type, and the whole typed `resolve` compiles again. For a plan with such ids, `resolve` does:

    normalized = normalize_ids(la)        # SimpleId{uuid} -> NormalizedId{k, R}, k = order of first appearance;
                                          # a handle keeps its original id in its `reconstructor` field
    resolved = _resolve_typed(normalized) # typed resolve, compiled once per plan shape
    restore_original_ids(resolved)        # every normalized handle back to the original one

While `resolve` runs, the registry holds the normalized handles, so its type is the same for every uuid, and their
runtime lookup keys are already those of the original ids (`dynamic_lookup_key`, IdReconstruction.jl). After
`resolve` the plan itself holds no ids, only each child's context name; the handles live in the registry, and the
last step puts the original ones back there, so a handle the user still holds is matched at compile time as before.

All of this runs on values held as `Any`, with `@nospecialize`, so it does not compile per uuid.
=#

"""Whether `T` contains a `SimpleId` with a random UUID anywhere in its type parameters."""
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

############################
###### NORMALIZING ######
############################

"""Normalizes random ids in types and values; `ordinals` numbers each uuid in order of first appearance."""
struct _IdNormalizer
    ordinals::Dict{UUID, Int}
    types::IdDict{Any, Any}
end
_IdNormalizer() = _IdNormalizer(Dict{UUID, Int}(), IdDict{Any, Any}())

_ordinal!(r::_IdNormalizer, u::UUID) = get!(r.ordinals, u, length(r.ordinals) + 1)

# No closures, `map` or `all` below: a closure capturing a fresh type, or `map` over a fresh tuple type, compiles per uuid.
function _normalize_type(r::_IdNormalizer, @nospecialize(T))
    T isa Union && return Union{_normalize_type(r, T.a), _normalize_type(r, T.b)}
    T isa DataType || return T
    isempty(T.parameters) && return T
    cached = get(r.types, T, nothing)
    isnothing(cached) || return cached
    normalized = if T <: SimpleId && T.parameters[1] isa UUID
        NormalizedId{_ordinal!(r, T.parameters[1]), IdReconstructor{SimpleId, UUID}}
    else
        params = T.parameters
        newparams = Vector{Any}(undef, length(params))
        changed = false
        for i in eachindex(newparams)
            newparams[i] = _normalize_param(r, params[i])
            changed |= newparams[i] !== params[i]
        end
        # A normalized handle's last parameter is the type of its reconstructor (it was `Nothing`).
        if T <: IdentifiableAlgo && newparams[2] isa NormalizedId
            newparams[6] = typeof(newparams[2]).parameters[2]
        end
        changed ? Core.apply_type(T.name.wrapper, newparams...) : T
    end
    r.types[T] = normalized
    return normalized
end

function _normalize_param(r::_IdNormalizer, @nospecialize(p))
    p isa Type && return _normalize_type(r, p)
    p isa TypeVar && return p
    return _normalize_value(r, p)
end

"""Rebuild `v` with normalized ids. Throws `_CannotNormalize` for mutable objects whose type would change."""
function _normalize_value(r::_IdNormalizer, @nospecialize(v))
    T = typeof(v)
    T2 = _normalize_type(r, T)
    T2 === T && return v
    (ismutable(v) || !(T2 isa DataType) || !isconcretetype(T2)) && throw(_CannotNormalize(T))
    n = fieldcount(T)
    fields = Vector{Any}(undef, n)
    for i in 1:n
        fields[i] = _normalize_value(r, getfield(v, i))
    end
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    if v isa IdentifiableAlgo && T2.parameters[6] !== T.parameters[6]
        fields[2] = IdReconstructor(T.parameters[2])    # keep the original id to rebuild it after `resolve`
    end
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T2, fields, n)
end

struct _CannotNormalize <: Exception
    type::Any
end

"""
    normalize_ids(la)

Replace every random `Unique` id in `la` by `NormalizedId{k, R}`, numbered in order of first appearance; each
normalized handle keeps its original id in its `reconstructor` field. The same plan shape with other uuids gives the
same normalized type. When a mutable object in the plan would change type it gives up and returns `la` unchanged;
that plan then resolves with its original ids, which is correct but compiles per uuid.
"""
Base.@nospecializeinfer function normalize_ids(@nospecialize(la))
    try
        return _normalize_value(_IdNormalizer(), la)
    catch e
        e isa _CannotNormalize || rethrow()
        return la
    end
end

############################
##### RESTORING ######
############################

"""Whether `T` contains a normalized id (`NormalizedId` or `IdReconstructor`) anywhere; results are cached in `cache`."""
function _type_has_normalized_ids(@nospecialize(T), cache::IdDict{Any, Bool})
    T isa Union && return _type_has_normalized_ids(T.a, cache) || _type_has_normalized_ids(T.b, cache)
    T isa DataType || return false
    cached = get(cache, T, nothing)
    isnothing(cached) || return cached
    cache[T] = false        # guards against recursion through the same type
    found = T <: NormalizedId || T <: IdReconstructor
    if !found
        for p in T.parameters
            found = p isa Type ? _type_has_normalized_ids(p, cache) :
                    p isa TypeVar ? false : _type_has_normalized_ids(typeof(p), cache)
            found && break
        end
    end
    cache[T] = found
    return found
end

"""
Rebuild `v` with every normalized handle replaced by the original one (`reconstruct_id` on its reconstructor). Only
the parts of `v` whose type contains a normalized id are rebuilt; a struct type parameter that is the type of a
rebuilt field gets that field's new type.
"""
function _restore_value(@nospecialize(v), cache::IdDict{Any, Bool})
    T = typeof(v)
    (ismutable(v) || !_type_has_normalized_ids(T, cache)) && return v
    if v isa IdentifiableAlgo && getfield(v, :reconstructor) isa IdReconstructor
        func = _restore_value(getfield(v, :func), cache)
        p = T.parameters
        return IdentifiableAlgo{typeof(func), reconstruct_id(getfield(v, :reconstructor)), p[3], p[4], p[5], Nothing}(func, nothing)
    end
    n = fieldcount(T)
    fields = Vector{Any}(undef, n)
    params = Any[T.parameters...]
    changed = false
    for i in 1:n
        old = getfield(v, i)
        new = _restore_value(old, cache)
        fields[i] = new
        new === old && continue
        changed = true
        for j in eachindex(params)
            params[j] === typeof(old) && (params[j] = typeof(new))
        end
    end
    changed || return v
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), Core.apply_type(T.name.wrapper, params...), fields, n)
end

"""
    restore_original_ids(resolved)

Put the original handles back wherever `resolve` left normalized ones, which is in the registry. The runtime lookup
tables need no change: their keys are those of the original ids already.
"""
Base.@nospecializeinfer restore_original_ids(@nospecialize(resolved)) = _restore_value(resolved, IdDict{Any, Bool}())

"""
Function barrier of `resolve` for plans with random ids: normalize, resolve the normalized type, then put the
original handles back (see the top of this file).

`@nospecializeinfer`: the caller knows the concrete random-id type, and plain `@nospecialize` would still infer this
body for that type, and the typed `resolve` it calls, which is the whole compile cost this barrier exists to avoid.
"""
@noinline Base.@nospecializeinfer function _resolve_normalized(@nospecialize(la))
    return restore_original_ids(_resolve_typed(normalize_ids(la)))
end
