#=
The `Unique` handles the user holds, found from types. The registry stores every handle numbered (`UniquePlanId{k}`);
the user holds `UniquePlanId{uuid}`. `resolve` puts the plan's `k => uuid` pairs into the registry's type
(`UniqueKeyMap`, the registry's `keymap`), so `registry[held]` and `context[held]` number the handle while compiling
(`numbered_handle`) and are lookups decided from types, as a registry key is. The user always gets the map: every plan
and context handed out keeps it (`setup`, `run(plan, context)`, `init(plan, context, ...)`, `getcontext(p)`,
`fetch(p)`). Running the plan (`init`, the loop) takes it out first (`strip_keymap`; the loop's plan and `LoopContext`
come without it from `prepare_for_loop`), so nothing they compile has a uuid in its type. A process keeps its
plan and its context with the map, as the user's (`getalgo(p)`, `getcontext(p)`); the map is in no process field. SA's
own code that needs a process's context without it reads `_getcontext_nokeymap`.
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
    # `all_algos(reg)`, read with `getfield`: a call of `all_algos` would compile for each registry type.
    entries = getfield(reg, :entries)
    for i in 1:nfields(entries)
        algos = getfield(getfield(entries, i), :algos)
        for j in 1:nfields(algos)
            algo = getfield(algos, j)
            algo isa IdentifiableAlgo || continue
            m = getfield(algo, :matcher)
            is_numbered_unique_id(m) && push!(pairs, plan_number(m) => origin(m))
        end
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
    is_held_unique_id(Id) || return :(obj)
    k = nothing
    for pair in P
        pair.second == plan_number(Id) && (k = pair.first; break)
    end
    isnothing(k) && return :(obj)
    NId = UniquePlanId{k}
    return :(IdentifiableAlgo{F, $NId, VA, AN, Key, $NId}(getfield(obj, :func), $NId(origin(getfield(obj, :matcher)))))
end
@inline numbered_handle(obj, ::Type) = obj
