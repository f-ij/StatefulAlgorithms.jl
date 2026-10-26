#=
Rewriting the `UniquePlanId`s in a value: `strip_unique` (Strip.jl) and `number_unique_ids` (Number.jl) are both this
one walk, with another `rewrite_id`.

`rewrite_unique_ids(v, rewrite)` rebuilds every part of `v` whose type mentions a `UniquePlanId`, giving each id
`rewrite_id(rewrite, id)`. A rebuilt struct gets its type parameters from its new fields: a parameter a field is declared
as becomes the new field's type, one worked out from a field (`list_field_derived_params`) is worked out again, and
the others are rewritten as values. It runs on values held as `Any`, with `@nospecialize`, so it compiles nothing per
uuid; the new types are made with `new_instance`.
=#

"""
    rewrite_unique_ids(v, rewrite) -> v with its `UniquePlanId`s rewritten

Rebuilds every part of `v` whose type mentions a `UniquePlanId`; each id becomes `rewrite_id(rewrite, id)`, an id only
a type holds `rewrite_type_id(rewrite, T)`. Mutable values are not rebuilt; one whose type mentions an id is an error.
"""
Base.@nospecializeinfer function rewrite_unique_ids(@nospecialize(v), rewrite)
    return _rewrite_value(v, rewrite, IdDict{Any, Bool}())
end

function _rewrite_value(@nospecialize(v), rewrite, cache::IdDict{Any, Bool})
    v isa Type && return _rewrite_type(v, rewrite, cache)
    T = typeof(v)
    _may_hold_unique_ids(T, cache) || return v
    v isa UniquePlanId && return rewrite_id(rewrite, v)
    mentions = _mentions_unique_ids(T, cache)
    if ismutable(v)
        mentions && error("Cannot rewrite the `Unique` ids inside a mutable value of type $T.")
        return v
    end
    n = nfields(v)
    fields = Vector{Any}(undef, n)
    changed = false
    for i in 1:n
        old = getfield(v, i)
        fields[i] = _rewrite_value(old, rewrite, cache)
        changed |= fields[i] !== old
    end
    (changed || mentions) || return v
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    v isa NamedTuple && return NamedTuple{T.parameters[1]}(Core._apply_iterate(iterate, tuple, fields))
    NT = Core.apply_type(T.name.wrapper, _rebuilt_params(T, fields, rewrite, cache)...)
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), NT, fields, n)
end

# The type parameters of `T` rebuilt with `fields`: from the fields where they come from a field, else rewritten.
function _rebuilt_params(@nospecialize(T::DataType), fields::Vector{Any}, rewrite, cache::IdDict{Any, Bool})
    params = Any[T.parameters...]
    from_field = falses(length(params))
    for i in eachindex(fields)
        j = _field_parameter_index(T, i)
        isnothing(j) && continue
        params[j] = typeof(fields[i])
        from_field[j] = true
    end
    _derive_params!(params, from_field, fields, list_field_derived_params(T))
    for j in eachindex(params)
        from_field[j] || params[j] isa TypeVar || (params[j] = _rewrite_value(params[j], rewrite, cache))
    end
    return params
end

# Specialized on the hook's answer (a few tuple types), so the loop over it is compiled, not dispatched per element.
function _derive_params!(params::Vector{Any}, from_field::BitVector, fields::Vector{Any}, derived::Tuple)
    for (j, i, derive) in derived
        isnothing(fields[i]) && continue
        params[j] = derive(fields[i])
        from_field[j] = true
    end
    return params
end

function _rewrite_type(@nospecialize(T), rewrite, cache::IdDict{Any, Bool})
    T isa Union && return Union{_rewrite_type(T.a, rewrite, cache), _rewrite_type(T.b, rewrite, cache)}
    T isa DataType || return T
    _mentions_unique_ids(T, cache) || return T
    T <: UniquePlanId && return rewrite_type_id(rewrite, T)
    params = Any[p isa TypeVar ? p : _rewrite_value(p, rewrite, cache) for p in T.parameters]
    return Core.apply_type(T.name.wrapper, params...)
end

"""Whether type `T` mentions a `UniquePlanId` anywhere in its parameters; cached in `cache`."""
function _mentions_unique_ids(@nospecialize(T), cache::IdDict{Any, Bool})
    T isa Union && return _mentions_unique_ids(T.a, cache) || _mentions_unique_ids(T.b, cache)
    T isa DataType || return false
    cached = get(cache, T, nothing)
    isnothing(cached) || return cached
    cache[T] = false        # guards against recursion through the same type
    found = T <: UniquePlanId
    if !found
        for p in T.parameters
            found = p isa Type ? _mentions_unique_ids(p, cache) :
                    p isa TypeVar ? false : _mentions_unique_ids(typeof(p), cache)
            found && break
        end
    end
    cache[T] = found
    return found
end

"""
Whether a value of the concrete type `T` may hold a `UniquePlanId`: its type mentions one, or a field of it may hold
one, where a field declared with an abstract type (`wires::Tuple`) always may. Mutable values are not looked into.
Cached in `cache` (under `(:may, T)`).
"""
function _may_hold_unique_ids(@nospecialize(T), cache::IdDict{Any, Bool})
    T isa DataType && isconcretetype(T) || return true
    _mentions_unique_ids(T, cache) && return true
    ismutabletype(T) && return false
    key = (:may, T)
    cached = get(cache, key, nothing)
    isnothing(cached) || return cached
    cache[key] = false      # guards against recursion through the same type
    found = false
    for i in 1:fieldcount(T)
        _may_hold_unique_ids(fieldtype(T, i), cache) && (found = true; break)
    end
    cache[key] = found
    return found
end
