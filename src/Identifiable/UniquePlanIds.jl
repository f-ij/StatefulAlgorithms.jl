#=
`Unique` handles in plans: stripping, numbering, and how the registry stores them.

A `Unique(f)` handle carries `UniquePlanId{uuid}(uuid)` (Matching.jl). Its id goes through three forms:

1. `strip_unique` (every constructor, and every input of a DSL block): `UniquePlanId{nothing}(uuid)`. Constructors
   then compile once for every new handle.
2. `number_unique_ids` (when a plan is built, `_build_plan`): `UniquePlanId{k}(uuid)`, `k` = 1, 2, ... in order of
   first appearance in the plan. A nested plan comes with its own numbers; they are renumbered into the new plan's,
   matched by uuid. The same code builds a plan of the same type for every new set of uuids.
3. `registry_matchers` (the last step of `resolve`): the registry stores each handle with
   `DoubleMatcher(UniquePlanId{k}(uuid), UniquePlanId{uuid}(uuid))`, so the plan's code finds it by `k` and the handle
   the user holds finds it by its uuid, both from types alone.

All three are one rewrite (`rewrite_unique_ids`) over values held as `Any`, with `@nospecialize`: it rebuilds every
part of a value whose type mentions a `UniquePlanId`, and gives each id its new form (`rewrite_id`) and each id that
only a type holds (a `Var`) its new number (`rewrite_type_number`). It compiles nothing per uuid.
=#

################################################
#################   REWRITE   ##################
################################################

"""
    new_instance(T, fields...) -> T

A value of the concrete type `T` with `fields` (of exactly its field types), made without calling a constructor. A new
type's default constructor is compiled on first call, about 1.5 ms each; `Unique` handles, the routes that hold them and
their registry matchers are new types for every uuid, so they are made with this.
"""
Base.@nospecializeinfer function new_instance(@nospecialize(T::DataType), @nospecialize(fields...))
    n = length(fields)
    v = Vector{Any}(undef, n)
    for i in 1:n
        v[i] = fields[i]
    end
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, v, n)
end

"""
    rewrite_unique_ids(v, rewrite) -> v with its `UniquePlanId`s rewritten

Rebuilds every part of `v` whose type mentions a `UniquePlanId`: each id value becomes `rewrite_id(rewrite, id)`, each
id only a type holds gets `rewrite_type_number(rewrite, N)`. A struct's type parameter that a field is declared as
becomes the new field's type; one that is the matcher of a field (`scref_derived_params`, a route's endpoints) is
worked out again from the new field. Mutable values are not rebuilt; one whose type mentions an id is an error.
"""
Base.@nospecializeinfer function rewrite_unique_ids(@nospecialize(v), rewrite)
    return _rewrite_value(v, rewrite, IdDict{Any, Bool}())
end

"""
    scref_derived_params(T) -> tuple of (parameter index => field index)

The type parameters of `T` that are the matcher (`scref_match`) of one of its fields, as a route stores its
endpoints: `rewrite_unique_ids` works them out again from the rewritten field. Default `()`.
Extended by: `Route`, `Share`, `Redirect`.
"""
scref_derived_params(::Type) = ()

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
    params = Any[T.parameters...]
    declared = falses(length(params))
    for i in 1:n
        j = _field_parameter_index(T, i)
        isnothing(j) && continue
        params[j] = typeof(fields[i])
        declared[j] = true
    end
    for (j, i) in scref_derived_params(T)
        isnothing(fields[i]) && continue
        params[j] = scref_match(fields[i])
        declared[j] = true
    end
    if v isa IdentifiableAlgo && !isnothing(fields[2])
        params[2] = static_id(fields[2])    # the type-level id follows the matcher in the `matcher` field
        declared[2] = true
    end
    for j in eachindex(params)
        declared[j] || (params[j] = rewrite_param(rewrite, params[j], cache))
    end
    NT = Core.apply_type(T.name.wrapper, params...)
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), NT, fields, n)
end

"""How a rewrite treats a type parameter that is not a field's type: rewritten as a value or type would be."""
function rewrite_param(rewrite, @nospecialize(p), cache::IdDict{Any, Bool})
    p isa TypeVar && return p
    return _rewrite_value(p, rewrite, cache)
end

function _rewrite_type(@nospecialize(T), rewrite, cache::IdDict{Any, Bool})
    T isa Union && return Union{_rewrite_type(T.a, rewrite, cache), _rewrite_type(T.b, rewrite, cache)}
    T isa DataType || return T
    _mentions_unique_ids(T, cache) || return T
    T <: UniquePlanId && return UniquePlanId{rewrite_type_number(rewrite, plan_number(T))}
    params = Any[rewrite_param(rewrite, p, cache) for p in T.parameters]
    return Core.apply_type(T.name.wrapper, params...)
end

################################################
##################   STRIP   ###################
################################################

struct _StripIds end
rewrite_id(::_StripIds, @nospecialize(id::UniquePlanId)) = plan_number(id) isa UUID ? UniquePlanId{nothing}(origin(id)) : id
# An id only a type holds keeps its uuid: without a value next to it, the uuid is all there is to number it by.
rewrite_type_number(::_StripIds, @nospecialize(N)) = N

"""
    strip_unique(x) -> x

`x` with the uuid of every `Unique` handle in it taken out of its type: `UniquePlanId{uuid}(uuid)` becomes
`UniquePlanId{nothing}(uuid)`. Constructors and DSL blocks call it on their inputs, so everything they compile sees
the same types for every new handle. Anything without a user-held `Unique` handle is returned as it is.
"""
Base.@nospecializeinfer strip_unique(@nospecialize(x)) = rewrite_unique_ids(x, _StripIds())

"""`strip_unique` on each element of the tuple `xs`."""
Base.@nospecializeinfer function strip_uniques(@nospecialize(xs::Tuple))
    out = Vector{Any}(undef, length(xs))
    for i in eachindex(out)
        out[i] = strip_unique(xs[i])
    end
    return Tuple(out)
end

################################################
##################   NUMBER   ##################
################################################

"""
The numbers of one plan: `numbers` maps each uuid to its number, in order of first appearance; `scope` maps the `N`
an id had in the scope being rewritten (a uuid, `nothing`, or the number its own plan gave it) to its new number.
"""
struct _NumberIds
    numbers::Dict{UUID, Int}
    scope::Dict{Any, Int}
    fallback::Dict{Any, Int}    # the numbers of all scopes, for a scope that holds an id only in a type
end

_number!(r::_NumberIds, u::UUID) = get!(r.numbers, u, length(r.numbers) + 1)

rewrite_id(r::_NumberIds, @nospecialize(id::UniquePlanId)) = UniquePlanId{_number!(r, origin(id))}(origin(id))

function rewrite_type_number(r::_NumberIds, @nospecialize(N))
    N isa UUID && return _number!(r, N)
    k = get(r.scope, N, nothing)
    isnothing(k) && (k = get(r.fallback, N, nothing))
    isnothing(k) && error("Cannot number a `UniquePlanId{$(repr(N))}` that only a type holds: no handle with that id is in the same part of the plan.")
    k < 0 && error("Cannot number a `UniquePlanId{$(repr(N))}` that only a type holds: several handles in the same part of the plan have that id.")
    return k
end

"""Push `(N, uuid)` for every `UniquePlanId` in `v` to `found`, values and types-only ids alike, in order."""
function _collect_unique_ids!(found::Vector{Tuple{Any, UUID}}, @nospecialize(v), cache::IdDict{Any, Bool})
    if v isa Type
        _collect_type_ids!(found, v, cache)
        return found
    end
    T = typeof(v)
    _may_hold_unique_ids(T, cache) || return found
    if v isa UniquePlanId
        push!(found, (plan_number(v), origin(v)))
        return found
    end
    ismutable(v) && return found
    for i in 1:nfields(v)
        _collect_unique_ids!(found, getfield(v, i), cache)
    end
    v isa Union{Tuple, NamedTuple} && return found
    for p in T.parameters
        p isa TypeVar || _collect_unique_ids!(found, p, cache)
    end
    return found
end

function _collect_type_ids!(found::Vector{Tuple{Any, UUID}}, @nospecialize(T), cache::IdDict{Any, Bool})
    if T isa Union
        _collect_type_ids!(found, T.a, cache); _collect_type_ids!(found, T.b, cache)
        return found
    end
    T isa DataType || return found
    _mentions_unique_ids(T, cache) || return found
    if T <: UniquePlanId
        N = plan_number(T)
        N isa UUID && push!(found, (N, N))     # a number or `nothing` is given by a value next to it
        return found
    end
    for p in T.parameters
        p isa TypeVar || _collect_unique_ids!(found, p, cache)
    end
    return found
end

"""
    number_unique_ids(scopes) -> scopes, numbered

Numbers the `Unique` handles of one plan. `scopes` is a tuple of parts of the plan whose ids belong together: a nested
plan (numbered on its own before) or the plan's other inputs. Every id gets the number of its uuid in order of first
appearance over all scopes (`UniquePlanId{k}(uuid)`); an id that only a type holds gets the number that its `N` has
among the values of its scope. Returns the scopes rewritten, in the same order. Untyped; compiles nothing per uuid.
"""
Base.@nospecializeinfer function number_unique_ids(@nospecialize(scopes::Tuple))
    cache = IdDict{Any, Bool}()
    founds = Vector{Vector{Tuple{Any, UUID}}}(undef, length(scopes))
    any_found = false
    for s in eachindex(founds)
        founds[s] = _collect_unique_ids!(Tuple{Any, UUID}[], scopes[s], cache)
        any_found |= !isempty(founds[s])
    end
    any_found || return scopes
    numbers = Dict{UUID, Int}()
    for found in founds, (_, u) in found
        get!(numbers, u, length(numbers) + 1)
    end
    scope_maps = Vector{Dict{Any, Int}}(undef, length(scopes))
    fallback = Dict{Any, Int}()
    for s in eachindex(scope_maps)
        scope_maps[s] = _scope_numbers!(Dict{Any, Int}(), founds[s], numbers)
        _scope_numbers!(fallback, founds[s], numbers)
    end
    out = Vector{Any}(undef, length(scopes))
    for s in eachindex(out)
        out[s] = isempty(founds[s]) ? scopes[s] : _rewrite_value(scopes[s], _NumberIds(numbers, scope_maps[s], fallback), cache)
    end
    return Tuple(out)
end

# Record the new number of each `N` in `found` in `scope`; -1 where two handles share an `N` (stripped ones, `nothing`).
function _scope_numbers!(scope::Dict{Any, Int}, found::Vector{Tuple{Any, UUID}}, numbers::Dict{UUID, Int})
    for (N, u) in found
        k = numbers[u]
        old = get(scope, N, k)
        scope[N] = old == k ? k : -1
    end
    return scope
end

################################################
#################   REGISTRY   #################
################################################

struct _RegistryIds end
rewrite_id(::_RegistryIds, @nospecialize(id::UniquePlanId)) = registry_matcher(id)
# Types only follow the handles' fields (a registry entry's handle types); nothing else in a registry holds an id.
rewrite_param(::_RegistryIds, @nospecialize(p), cache::IdDict{Any, Bool}) = p

"""
    registry_matcher(id) -> matcher

The matcher a registry stores a handle with, when `resolve` is done: for a numbered `Unique` handle,
`DoubleMatcher(UniquePlanId{k}(uuid), UniquePlanId{uuid}(uuid))`; any other id as it is.
"""
registry_matcher(id) = id
function registry_matcher(@nospecialize(id::UniquePlanId))
    plan_number(id) isa Int || return id
    held = user_unique_id(origin(id))
    return new_instance(DoubleMatcher{typeof(id), typeof(held)}, id, held)
end

"""The matcher of the handle the user holds, `UniquePlanId{u}(u)`, made without compiling its constructor."""
Base.@nospecializeinfer user_unique_id(u::UUID) = new_instance(UniquePlanId{u}, u)

"""
    registry_matchers(resolved) -> resolved

`resolved` with every registry in it storing its `Unique` handles with their `registry_matcher`
(`DoubleMatcher(UniquePlanId{k}(uuid), UniquePlanId{uuid}(uuid))`); the last step of `resolve`. Everything outside the
registries (the plan) keeps the numbered ids. Untyped; compiles nothing per uuid.
"""
Base.@nospecializeinfer registry_matchers(@nospecialize(resolved)) = _rewrite_registries(resolved, IdDict{Any, Bool}())

function _rewrite_registries(@nospecialize(v), cache::IdDict{Any, Bool})
    v isa Type && return v
    T = typeof(v)
    _mentions_unique_ids(T, cache) || return v
    v isa NameSpaceRegistry && return _rewrite_value(v, _RegistryIds(), cache)
    (ismutable(v) || v isa UniquePlanId) && return v
    n = nfields(v)
    fields = Vector{Any}(undef, n)
    changed = false
    for i in 1:n
        old = getfield(v, i)
        fields[i] = _rewrite_registries(old, cache)
        changed |= fields[i] !== old
    end
    changed || return v
    v isa Tuple && return Core._apply_iterate(iterate, tuple, fields)
    v isa NamedTuple && return NamedTuple{T.parameters[1]}(Core._apply_iterate(iterate, tuple, fields))
    params = Any[T.parameters...]
    for i in 1:n
        j = _field_parameter_index(T, i)
        isnothing(j) || (params[j] = typeof(fields[i]))
    end
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), Core.apply_type(T.name.wrapper, params...), fields, n)
end
