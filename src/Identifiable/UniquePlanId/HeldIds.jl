#=
The `Unique` handles the user holds, in a context handed to the user. The registry stores every handle numbered
(`UniquePlanId{k}`); the user holds `UniquePlanId{uuid}`. A context handed to the user (`context(p)`, `fetch(p)`) carries
the plan's `k => uuid` pairs in its type (`UniqueKeyMap`, in its `HeldRegistry`), so `context[held]` numbers the handle
while compiling (`numbered_handle`) and is a lookup decided from types, as a registry key is.
=#

"""
    UniqueKeyMap{P}

The numbers a plan gave its `Unique` handles, as type data: `P` is a tuple of `k => uuid` pairs, one per handle in the
registry (`UniquePlanId{k}(uuid)`). A context handed to the user carries it (`HeldRegistry`), so a handle the user holds
(`UniquePlanId{uuid}`) is turned into its numbered one while compiling (`numbered_handle`) and found from types.
"""
struct UniqueKeyMap{P} end

"""
    HeldRegistry{RR, M}

The registry field of a context handed to the user (`with_held_ids`): the registry `Ref` as SA works with it (`ref`,
numbered handles only) and the plan's `UniqueKeyMap` `M`. Only the type is new for every set of `Unique` handles; the
registry is the same object.
"""
struct HeldRegistry{RR, M}
    ref::RR
end
@inline _unref(h::HeldRegistry) = getfield(h, :ref)[]

"""
    unique_key_map(registry) -> UniqueKeyMap or nothing

The `UniqueKeyMap` of the `Unique` handles in `registry`, in the order of their numbers; `nothing` when it has none.
Untyped.
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
map, decided while compiling. Any other value, or a handle the map does not have, as it is.
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
    with_held_ids(x, keymap) -> x

The context `x` as it is handed to the user: its registry field becomes a `HeldRegistry` carrying `keymap` (a
`UniqueKeyMap`) in its type, so a `Unique` handle the user holds is found from types (`context[handle]`), like a registry
key. Same subcontexts and registry, not copies. Anything that is not a `ProcessContext`, or without a map, as it is.
Untyped: made at run time, compiling nothing per uuid.
"""
Base.@nospecializeinfer function with_held_ids(@nospecialize(x), @nospecialize(keymap))
    x isa ProcessContext && !isnothing(keymap) || return x
    ref = registryref(x)
    ref isa Base.RefValue || return x
    held = new_instance(Core.apply_type(HeldRegistry, typeof(ref), typeof(keymap)), ref)
    subcontexts = get_subcontexts(x)
    return new_instance(Core.apply_type(ProcessContext, typeof(subcontexts), typeof(held)), subcontexts, held)
end

"""`with_held_ids` with the map of `x`'s own registry (`unique_key_map`), made once per registry and cached."""
Base.@nospecializeinfer function with_held_ids(@nospecialize(x))
    x isa ProcessContext || return x
    ref = registryref(x)
    ref isa Base.RefValue || return x
    return with_held_ids(x, cached_key_map(ref))
end

"""
    strip_held_ids(x) -> x

A context handed to the user, back as SA works with it (the registry `Ref` without its `UniqueKeyMap`); for a context
the user passes back in (`Process(...; context)`), so nothing SA compiles has a uuid in its type.
"""
Base.@nospecializeinfer function strip_held_ids(@nospecialize(x))
    x isa ProcessContext || return x
    held = registryref(x)
    held isa HeldRegistry || return x
    ref = getfield(held, :ref)
    subcontexts = get_subcontexts(x)
    return new_instance(Core.apply_type(ProcessContext, typeof(subcontexts), typeof(ref)), subcontexts, ref)
end

# The `UniqueKeyMap` of the registry in `ref`, made once per registry (the contexts of one plan share their registry
# `Ref`). The values are boxed (`Ref{Any}`), so the cache's methods compile once, not for every new map type.
const _KEY_MAPS = WeakKeyDict{Base.RefValue, Base.RefValue{Any}}()
const _KEY_MAPS_LOCK = ReentrantLock()
Base.@nospecializeinfer function cached_key_map(@nospecialize(ref::Base.RefValue))
    boxed = @lock _KEY_MAPS_LOCK get!(() -> Ref{Any}(unique_key_map(ref[])), _KEY_MAPS, ref)
    return boxed[]
end
