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

# The expression that builds `ex` (a value of type `T`) with the ids at `locations[lo:hi]` numbered by `mode`, worked
# out from `T` alone, as `replace_unique_ids` builds the value (`_rebuild_along`): each struct on a path gets the type
# `replace_ids_in_type` gives, so a parameter a holder works out from a field (a handle's id, a route's matchers) is
# numbered from its own uuid, as the field is. Runs while generating code.
function _numbered_expr(@nospecialize(T), ex, locations::Vector{UniqueIdLocation}, lo::Int, hi::Int, depth::Int, mode::_MapIds)
    if length(locations[lo].path) == depth
        holds_type(locations[lo]) && return QuoteNode(replace_ids_in_type(T.parameters[1], mode))
        NT = replace_type_id(mode, T)
        return NT === T ? ex : :($NT(origin($ex)))
    end
    exprs = Any[:(getfield($ex, $i)) for i in 1:fieldcount(T)]
    first_of_group = lo
    while first_of_group <= hi
        i = step_index(locations[first_of_group].path[depth + 1])
        last_of_group = first_of_group
        while last_of_group < hi && step_index(locations[last_of_group + 1].path[depth + 1]) == i
            last_of_group += 1
        end
        exprs[i] = _numbered_expr(fieldtype(T, i), exprs[i], locations, first_of_group, last_of_group, depth + 1, mode)
        first_of_group = last_of_group + 1
    end
    T <: Tuple && return :(tuple($(exprs...)))
    T <: NamedTuple && return :(NamedTuple{$(T.parameters[1])}(tuple($(exprs...))))
    return Expr(:new, replace_ids_in_type(T, mode), exprs...)
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
    locations = try unique_id_locations(X) catch; return :(number_by_keymap_dynamic(x, keymap)) end
    isempty(locations) && return :x
    all(l -> holds_type(l) || is_held_unique_id(l.leaftype), locations) || return :(number_by_keymap_dynamic(x, keymap))
    return _numbered_expr(X, :x, locations, 1, length(locations), 0, _MapIds(numbers))
end
@inline number_by_keymap(x, ::Nothing) = x
