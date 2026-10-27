#=
The `Unique` handles the user holds, found from types. The registry stores every handle numbered (`UniquePlanId{k}`);
the user holds `UniquePlanId{uuid}`. `resolve` puts the plan's `k => uuid` pairs into the registry's type
(`UniqueKeyMap`, the registry's `keymap`), so `registry[held]` and `context[held]` number the handle while compiling
(`numbered_handle`) and are lookups decided from types, as a registry key is. Running the plan (`init`, the loop) takes
the map out first (`strip_keymap`), so nothing they compile has a uuid in its type; a process keeps the map as a value
and puts it back into the contexts it hands to the user.
=#

"""
    UniqueKeyMap{P}

The numbers a plan gave its `Unique` handles, as type data: `P` is a tuple of `k => uuid` pairs, one per handle in the
registry (`UniquePlanId{k}(uuid)`). The registry of a resolved plan carries it (`keymap`), so a handle the user holds
(`UniquePlanId{uuid}`) is turned into its numbered one while compiling (`numbered_handle`) and found from types.
"""
struct UniqueKeyMap{P} end

"""
    unique_key_map(registry) -> UniqueKeyMap or nothing

The `UniqueKeyMap` of the `Unique` handles in `registry`, in the order of their numbers; `nothing` when it has none.
Made by `resolve`, once per plan. Untyped.
"""
Base.@nospecializeinfer function unique_key_map(@nospecialize(reg))
    pairs = Pair{Int, UUID}[]
    for algo in all_algos(reg)
        algo isa IdentifiableAlgo || continue
        m = getfield(algo, :matcher)
        m isa UniquePlanId && plan_number(m) isa Int && push!(pairs, plan_number(m) => origin(m))
    end
    isempty(pairs) && return nothing
    sort!(pairs; by = first)
    return new_instance(Core.apply_type(UniqueKeyMap, Tuple(pairs)))
end

"""
    numbered_handle(handle, UniqueKeyMap{P})

The handle the user holds as the plan numbered it: `UniquePlanId{uuid}` becomes `UniquePlanId{k}`, with `k` from the
map, decided while compiling. Any other value, a handle the map does not have, or no map (`Nothing`), as it is.
"""
@generated function numbered_handle(obj::IdentifiableAlgo{F, Id, VA, AN, Key, Mt}, ::Type{UniqueKeyMap{P}}) where {F, Id, VA, AN, Key, Mt, P}
    Id <: UniquePlanId && plan_number(Id) isa UUID || return :(obj)
    k = nothing
    for pair in P
        pair.second == plan_number(Id) && (k = pair.first; break)
    end
    isnothing(k) && return :(obj)
    NId = UniquePlanId{k}
    return :(IdentifiableAlgo{F, $NId, VA, AN, Key, $NId}(getfield(obj, :func), $NId(origin(getfield(obj, :matcher)))))
end
@inline numbered_handle(obj, ::Type) = obj

"""
    getkeymap(x) -> UniqueKeyMap or nothing

The `UniqueKeyMap` in the registry of `x` (a registry, a context, a plan); `nothing` when it has none. Untyped.
"""
Base.@nospecializeinfer function getkeymap(@nospecialize(x))
    reg = _registry_field(x)
    return reg isa NameSpaceRegistry ? getfield(reg, :keymap) : nothing
end

# The registry of `x`, read with `getfield` only: the plans and contexts here have the map in their types, and a call
# of an accessor on them would compile once for every new set of `Unique` handles.
Base.@nospecializeinfer function _registry_field(@nospecialize(x))
    x isa NameSpaceRegistry && return x
    x isa FinalizedAlgorithm && return _registry_field(getfield(x, :inner))
    x isa LoopAlgorithm && return getfield(x, :reg)
    if x isa ProcessContext
        ref = getfield(x, :reg)
        return ref isa Base.RefValue ? ref[] : nothing
    end
    return nothing
end

"""
    with_keymap(x, keymap) -> x

`x` (a registry, a context, a `LoopAlgorithm` or `FinalizedAlgorithm`) with `keymap` (a `UniqueKeyMap` or `nothing`)
as its registry's map: in a plan, both its registry and its persistent context's. Same entries, subcontexts and plan,
not copies; anything else as it is. Untyped: made at run time, compiling nothing per uuid.
"""
Base.@nospecializeinfer function with_keymap(@nospecialize(x), @nospecialize(keymap))
    # Fields read with `getfield` only, as in `_registry_field`.
    if x isa NameSpaceRegistry
        getfield(x, :keymap) === keymap && return x
        entries = getfield(x, :entries)
        return new_instance(Core.apply_type(NameSpaceRegistry, typeof(entries), typeof(keymap)), entries, keymap)
    elseif x isa ProcessContext
        ref = getfield(x, :reg)
        ref isa Base.RefValue || return x
        reg = with_keymap(ref[], keymap)
        reg === ref[] && return x
        newref = new_instance(Core.apply_type(Base.RefValue, typeof(reg)), reg)
        subcontexts = getfield(x, :subcontexts)
        return new_instance(Core.apply_type(ProcessContext, typeof(subcontexts), typeof(newref)), subcontexts, newref)
    elseif x isa FinalizedAlgorithm
        inner = with_keymap(getfield(x, :inner), keymap)
        final = getfield(x, :final)
        return new_instance(Core.apply_type(FinalizedAlgorithm, typeof(inner), typeof(final)), inner, final)
    elseif x isa LoopAlgorithm
        reg = getfield(x, :reg)
        reg isa NameSpaceRegistry || return x
        reg = with_keymap(reg, keymap)
        context = with_keymap(getfield(x, :context), keymap)
        p = typeof(x).parameters    # {Plan, O, R, C, Inits, Overrides, id}
        T = Core.apply_type(LoopAlgorithm, p[1], p[2], typeof(reg), typeof(context), p[5], p[6], p[7])
        return new_instance(T, getfield(x, :plan), getfield(x, :options), reg, context, getfield(x, :inits), getfield(x, :overrides))
    end
    return x
end

"""
    strip_keymap(x) -> x

`x` without its registry's `UniqueKeyMap` (`with_keymap(x, nothing)`): what `init` and the loop compile for, so a new
set of `Unique` handles compiles nothing again.
"""
Base.@nospecializeinfer strip_keymap(@nospecialize(x)) = with_keymap(x, nothing)

"""
    number_by_keymap(x, keymap::UniqueKeyMap) -> x, numbered as the plan numbers its handles

What `number_by_keymap_dynamic` does, decided while compiling: the numbered value is built by code generated for
`typeof(x)` and the map's type, so it is inferred and costs no walk at run time. Used by the typed handles
(`run(ip; lifetime)`, `run(p; lifetime)`), whose type has the map. Compiled once per value type and map, as the handle's
own methods are. Where the type alone does not say how to number (an id stripped or numbered elsewhere, whose uuid is
only in the value; a holder whose type parameters are worked out from its fields, `list_field_derived_params`; a
field of an abstract type), it numbers at run time (`number_by_keymap_dynamic`), not inferred. With no map (`nothing`)
`x` as it is.
"""
@generated function number_by_keymap(x::X, keymap::K) where {X, K<:UniqueKeyMap}
    numbers = Dict{UUID, Int}()
    for pair in K.parameters[1]
        numbers[pair.second] = pair.first
    end
    built = _build_numbered_expr(X, :x, _MapIds(numbers), IdDict{Any, Bool}())
    isnothing(built) && return :(number_by_keymap_dynamic(x, keymap))
    return first(built)
end
@inline number_by_keymap(x, ::Nothing) = x

# `(expression, type)` of `ex` (a value of type `T`) numbered by `mode`, worked out from `T` alone, or `nothing` when
# `T` does not say how (see `number_by_keymap`). Runs while generating code.
function _build_numbered_expr(@nospecialize(T), ex, mode::_MapIds, cache::IdDict{Any, Bool})
    T isa DataType || return nothing
    _may_hold_unique_ids(T, cache) || return (ex, T)
    if T <: UniquePlanId
        N = plan_number(T)
        N isa UUID || return nothing
        k = get(mode.numbers, N, nothing)
        isnothing(k) && return (ex, T)
        return (:(UniquePlanId{$k}(origin($ex))), UniquePlanId{k})
    end
    if T <: Type
        NewType = _rewrite_type(T.parameters[1], mode, cache)
        return (QuoteNode(NewType), Type{NewType})
    end
    ismutabletype(T) && return nothing
    isempty(list_field_derived_params(T)) || return nothing
    exprs = Any[]
    types = Any[]
    for i in 1:fieldcount(T)
        built = _build_numbered_expr(fieldtype(T, i), :(getfield($ex, $i)), mode, cache)
        isnothing(built) && return nothing
        push!(exprs, built[1])
        push!(types, built[2])
    end
    T <: Tuple && return (:(tuple($(exprs...))), Tuple{types...})
    if T <: NamedTuple
        names = T.parameters[1]
        return (:(NamedTuple{$names}(tuple($(exprs...)))), NamedTuple{names, Tuple{types...}})
    end
    params = Any[T.parameters...]
    from_field = falses(length(params))
    for i in eachindex(types)
        j = _field_parameter_index(T, i)
        isnothing(j) && continue
        params[j] = types[i]
        from_field[j] = true
    end
    for j in eachindex(params)
        from_field[j] || params[j] isa TypeVar || (params[j] = _rewrite_value(params[j], mode, cache))
    end
    NT = Core.apply_type(T.name.wrapper, params...)
    return (Expr(:new, NT, exprs...), NT)
end
