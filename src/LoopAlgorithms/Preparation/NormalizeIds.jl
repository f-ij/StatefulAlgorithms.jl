#=
Normalizing the random ids of `Unique` handles around `resolve`.

`Unique(f)` puts a random UUID in the handle's type (`SimpleId{uuid}()`), so every re-run of the same user code
gives a plan of a new type, and the whole typed `resolve` compiles again. For a plan with such ids, `resolve` does:

    normalized, uuids = normalize_ids(la)          # SimpleId{uuid} -> NormalizedId{k}, k = order of first appearance
    resolved = _resolve_typed(normalized)          # typed resolve, compiled once per plan shape
    registry = unnormalize_registry(getregistry(resolved), uuids)
    attach_registry_to_tree(resolved, registry)    # NormalizedId{k} -> SimpleId{uuid} again, in the registry only

After `resolve` the plan itself holds no ids, only each child's context name (`Namespace{:Counter_1}`). The ids are
only needed in the registry, where a handle the user still holds (`context[handle]`, `Init(handle; ...)`) is matched
at compile time by its id to that name. So the registry gets the original uuids back.

The (un)normalizing runs on type objects and values held as `Any`, with `@nospecialize`, so it does not compile per
uuid.
=#

"""
    NormalizedId{k}

Matcher that stands in for the `k`-th random `Unique` id (in order of first appearance) while `resolve` runs. A type of
its own, so it cannot clash with ids users choose (`SimpleId(...)`). It never appears outside `resolve`.
"""
struct NormalizedId{k} <: AbstractMatcher{k} end

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

"""
Rewrites ids in types and values, in one direction:
`SimpleId{uuid}` to `NormalizedId{k}` (`normalize = true`, filling `uuids` in order of first appearance), or
`NormalizedId{k}` back to `SimpleId{uuids[k]}` (`normalize = false`).
"""
struct _IdRewriter
    normalize::Bool
    uuids::Vector{UUID}
    ordinals::Dict{UUID, Int}
    types::IdDict{Any, Any}
end
_IdRewriter(normalize::Bool, uuids::Vector{UUID} = UUID[]) =
    _IdRewriter(normalize, uuids, Dict{UUID, Int}(u => k for (k, u) in enumerate(uuids)), IdDict{Any, Any}())

function _ordinal!(r::_IdRewriter, u::UUID)
    k = get(r.ordinals, u, nothing)
    isnothing(k) || return k
    push!(r.uuids, u)
    return r.ordinals[u] = length(r.uuids)
end

"""The rewritten type of an id matcher type, or `nothing` when `T` is not an id this rewriter changes."""
function _rewrite_id_type(r::_IdRewriter, @nospecialize(T::DataType))
    if r.normalize
        T <: SimpleId && T.parameters[1] isa UUID && return NormalizedId{_ordinal!(r, T.parameters[1])}
    else
        T <: NormalizedId && return SimpleId{r.uuids[T.parameters[1]]}
    end
    return nothing
end

# No closures, `map` or `all` below: a closure capturing a fresh type, or `map` over a fresh tuple type, compiles per uuid.
function _rewrite_type(r::_IdRewriter, @nospecialize(T))
    T isa Union && return Union{_rewrite_type(r, T.a), _rewrite_type(r, T.b)}
    T isa DataType || return T
    isempty(T.parameters) && return T
    cached = get(r.types, T, nothing)
    isnothing(cached) || return cached
    rewritten = _rewrite_id_type(r, T)
    if isnothing(rewritten)
        params = T.parameters
        newparams = Vector{Any}(undef, length(params))
        changed = false
        for i in eachindex(newparams)
            newparams[i] = _rewrite_param(r, params[i])
            changed |= newparams[i] !== params[i]
        end
        rewritten = changed ? Core.apply_type(T.name.wrapper, newparams...) : T
    end
    r.types[T] = rewritten
    return rewritten
end

function _rewrite_param(r::_IdRewriter, @nospecialize(p))
    p isa Type && return _rewrite_type(r, p)
    p isa TypeVar && return p
    return _rewrite_value(r, p)
end

"""Rebuild `v` with rewritten ids. Throws `_CannotRewrite` for mutable objects whose type would change."""
function _rewrite_value(r::_IdRewriter, @nospecialize(v))
    T = typeof(v)
    T2 = _rewrite_type(r, T)
    T2 === T && return v
    (ismutable(v) || !(T2 isa DataType) || !isconcretetype(T2)) && throw(_CannotRewrite(T))
    n = fieldcount(T)
    fields = Vector{Any}(undef, n)
    for i in 1:n
        fields[i] = _rewrite_value(r, getfield(v, i))
    end
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T2, fields, n)
end

struct _CannotRewrite <: Exception
    type::Any
end

"""
    normalize_ids(la) -> (normalized, uuids)

Replace every random `Unique` id in `la` by `NormalizedId{k}`, numbered in order of first appearance; `uuids[k]` is
the original uuid. The same plan shape with other uuids gives the same normalized type. When a mutable object in the
plan would change type it gives up and returns `la` unchanged with no uuids; that plan then resolves with its
original ids, which is correct but compiles per uuid.
"""
Base.@nospecializeinfer function normalize_ids(@nospecialize(la))
    r = _IdRewriter(true)
    normalized = try
        _rewrite_value(r, la)
    catch e
        e isa _CannotRewrite || rethrow()
        return la, UUID[]
    end
    return normalized, r.uuids
end

"""
    unnormalize_registry(registry, uuids) -> registry

The same registry with every `NormalizedId{k}` replaced by the original `SimpleId{uuids[k]}`, in the entries' types
and in the keys of their runtime lookup tables: the registry `resolve` would have built from the original plan.
"""
Base.@nospecializeinfer function unnormalize_registry(@nospecialize(registry::NameSpaceRegistry), uuids::Vector{UUID})
    r = _IdRewriter(false, uuids)
    type_entries = getentries(registry)
    rewritten = Vector{Any}(undef, length(type_entries))
    for i in eachindex(rewritten)
        rte = type_entries[i]
        lookup = Dict{Any, Int}()
        for (matcher, idx) in getdynamiclookup(rte)
            lookup[_rewrite_value(r, matcher)] = idx
        end
        rewritten[i] = RegistryTypeEntry{gettype(rte)}(_rewrite_value(r, getentries(rte)), copy(getmultipliers(rte)), lookup)
    end
    entries = Tuple(rewritten)
    return NameSpaceRegistry{typeof(entries)}(entries)
end

"""
Function barrier of `resolve` for plans with random ids: normalize, resolve the normalized type, then put the original
ids back into the registry (see the top of this file).

`@nospecializeinfer`: the caller knows the concrete random-id type, and plain `@nospecialize` would still infer this
body for that type, and the typed `resolve` it calls, which is the whole compile cost this barrier exists to avoid.
"""
@noinline Base.@nospecializeinfer function _resolve_normalized(@nospecialize(la))
    normalized, uuids = normalize_ids(la)
    resolved = _resolve_typed(normalized)
    isempty(uuids) && return resolved
    return attach_registry_to_tree(resolved, unnormalize_registry(getregistry(resolved), uuids))
end
