export resolve

#=
Resolving a plan: everything that can only be decided once the whole composition is known.

1. Registry: every algorithm and state in the tree gets a key (`Sensor_1`, `Sensor_2`, ...).
   Children are replaced by their raw algorithm and the key goes into the plan's `namespaces`.
   Calls (`Callable`) have no identity: they are not registered and share `:_captured_returns`.
2. The registry is attached to the root wrapper and to nested `LoopAlgorithm` wrappers.
3. Wiring: route/share endpoints become context keys, and plan-wide wiring is copied into each
   child's slot.
4. Scopes: each plan node records (in its `PlanWiring` type) its scope, the declared locals and
   captured returns its children see by name (`Scope`), and routes that read them point at
   their slots.

The sections below follow these steps.
=#

"""
Materialize a loop algorithm for context construction.

This wraps bare plan nodes in a concrete `LoopAlgorithm`, builds a registry,
keys the child algorithms, resolves the route/share wiring against that
registry, and collects the `RootOption`s of the plan tree. The returned value is always a runtime wrapper unless the input was a
`FinalizedAlgorithm`, in which case the finalized outer shape is preserved and
its inner loop is materialized.

Untyped: the result is not inferred (a caller gets `Any`), and each step is compiled on its own for the types it gets
(`_resolve_untyped`), which keeps the first resolve of a plan cheap. Plans with `Unique` handles are resolved with
their random ids normalized, so the same layout with new ids compiles nothing again (NormalizeIds.jl). The inferred
version, for a caller that knows the plan type, is `_resolve_typed` (Typed.jl).
"""
Base.@nospecializeinfer function resolve(@nospecialize(la::LoopSpec))
    _has_unique_handles(la) || return _resolve_untyped(la)
    return restore_original_ids(_resolve_untyped(normalize_ids(la)))
end

"""
The steps of resolving `la` (see the top of this file), each called on the runtime value: a dynamic dispatch per step,
so every step is compiled for the types it gets and nothing is inlined or inferred across the steps.
"""
@noinline Base.@nospecializeinfer function _resolve_untyped(@nospecialize(la))
    la isa FinalizedAlgorithm && return finalstep(_resolve_untyped(inneralgorithm(la)), finalfunction(la))
    la isa LoopAlgorithm || return _resolve_untyped(LoopAlgorithm(la))
    isresolved(la) && return la

    registry, keyed_la = setup_registry_and_keyed_algos(la)   # 1. keys and namespaces
    keyed_la = attach_registry_to_tree(keyed_la, registry)     # 2. share the registry
    keyed_la = resolve_plan_wiring(keyed_la, registry)         # 3. and 4. routes, shares, scopes
    # The `RootOption`s of the plan tree stay on the root wrapper.
    return setoptions(keyed_la, _root_options(la))
end

# Replace the children of a plan, of the plan inside a wrapper, or inside a finalized algorithm. Used by every step.
@inline function rebuild_loopalgorithm_funcs(la::LA, funcs::F) where {LA<:AbstractPlan, F<:Tuple}
    return setfield(la, :funcs, funcs)
end

@inline function rebuild_loopalgorithm_funcs(la::LA, funcs::F) where {LA<:LoopSpec, F}
    return setfield(la, :funcs, funcs)
end

@inline function rebuild_loopalgorithm_funcs(la::LoopAlgorithm, funcs::F) where {F}
    return setfield(la, :plan, rebuild_loopalgorithm_funcs(getplan(la), funcs))
end

@inline function rebuild_loopalgorithm_funcs(fa::FA, funcs::F) where {FA<:FinalizedAlgorithm, F}
    return finalstep(rebuild_loopalgorithm_funcs(inneralgorithm(fa), funcs), finalfunction(fa))
end

############################################################################################
# 1. Registry
############################################################################################

"""Build the registry for the whole tree and return it with the keyed plan."""
@inline function setup_registry_and_keyed_algos(la::LoopAlgorithm)
    registry = NameSpaceRegistry()

    # States are context-owned entries. They are registered first so the final
    # registry keeps the same ordering as `setup_registry`.
    states = flat_states(la)
    multipliers = ntuple(i -> 1, length(states))
    registry = addall(registry, states, multipliers)

    registry, named_plan = add_algos_to_registry(registry, getplan(la), 1.0)
    return registry, setfield(la, :plan, named_plan)
end

"""
Register the children of a plan node. Each child's multiplier (how often it runs per root step)
is the parent's times its own interval/repeat factor. Returns the plan with raw children and
their namespaces.
"""
@inline function add_algos_to_registry(registry::R, la::LA, multiplier) where {R<:NameSpaceRegistry, LA<:AbstractPlan}
    funcs = getalgos(la)
    algo_multipliers = tuplemap(m -> multiplier * m, multipliers(la))
    registry, raw_funcs, namespaces = add_algo_tuple_to_registry(registry, funcs, algo_multipliers)
    return registry, setfield(rebuild_loopalgorithm_funcs(la, raw_funcs), :namespaces, namespaces)
end

# A wrapper (`LoopAlgorithm`, `FinalizedAlgorithm`) rather than a plan: reached through a named
# nested plan. Its children are registered, but no `namespaces` are recorded on it here.
@inline function add_algos_to_registry(registry::R, la::LA, multiplier) where {R<:NameSpaceRegistry, LA<:LoopSpec}
    funcs = getalgos(la)
    algo_multipliers = tuplemap(m -> multiplier * m, multipliers(la))
    registry, raw_funcs, _ = add_algo_tuple_to_registry(registry, funcs, algo_multipliers)
    return registry, rebuild_loopalgorithm_funcs(la, raw_funcs)
end

"""
    add_algo_tuple_to_registry(registry, funcs, multipliers) -> (registry, raw_funcs, namespaces)

Register the children of one plan, first to last, each with its multiplier. Returns the registry with the children
added, the children as the plan stores them afterwards (a plain algorithm without its identifiable wrapper, or a
nested plan whose own children are registered too), and per child its context name as a `Namespace` type
(`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan).
"""
@inline function add_algo_tuple_to_registry(registry::R, funcs::F, multipliers::M) where {R<:NameSpaceRegistry, F<:Tuple, M<:Tuple}
    # Written as recursion over the front of the tuple that adds the last child to the registry it gets back, so that
    # the registry's type stays known: it grows with every child, and recursing over the tail instead (passing the
    # growing registry down as an argument) makes Julia give up and use plain `NameSpaceRegistry`. Here the arguments
    # only get shorter, which works for any number of children.
    reg, raws, names = add_algo_tuple_to_registry(registry, Base.front(funcs), Base.front(multipliers))
    reg, raw, name = add_algo_to_registry(reg, last(funcs), last(multipliers))
    return reg, (raws..., raw), (names..., name)
end
@inline add_algo_tuple_to_registry(registry::R, ::Tuple{}, ::Tuple{}) where {R<:NameSpaceRegistry} = registry, (), ()

# An algorithm or state: the registry assigns its key. The plan keeps the raw algorithm and the
# key as its namespace, so the plan's types do not depend on identity wrappers.
@inline function add_algo_to_registry(registry::R, algo::A, multiplier) where {R<:NameSpaceRegistry, A}
    registry, keyed_algo = add(registry, algo, multiplier)
    return registry, getalgo(keyed_algo), Namespace{getkey(keyed_algo)}()
end

"""Plain function calls have no state or identity: not registered, all in their `fixed_namespace`."""
@inline add_algo_to_registry(registry::R, ex::EX, multiplier) where {R<:NameSpaceRegistry, EX<:Callable} =
    registry, ex, Namespace{fixed_namespace(ex)}()

# A nested plan introduces no namespace: register its children instead, which carry theirs.
# `Namespace{nothing}` only fills the plan's slot in `namespaces`.
@inline function add_algo_to_registry(registry::R, algo::LA, multiplier) where {R<:NameSpaceRegistry, LA<:LoopSpec}
    inner = algo isa LoopAlgorithm ? getplan(algo) : algo
    registry, plan = add_algos_to_registry(registry, inner, multiplier)
    return registry, plan, Namespace{nothing}()
end

# The same for a nested plan that was given a name. Construction rejects `:name => plan`, but
# `IdentifiableAlgo(plan, :name)` and `insert(la, i, :name => plan)` get here; the name is dropped.
# TODO (TODO.md, "named plans as context slices"): record the name here as `:name => (child SCKeys...)`.
@inline function add_algo_to_registry(registry::R, algo::IA, multiplier) where {F<:LoopSpec, R<:NameSpaceRegistry, IA<:AbstractIdentifiableAlgo{F}}
    registry, plan = add_algos_to_registry(registry, getalgo(algo), multiplier)
    return registry, plan, Namespace{nothing}()
end

############################################################################################
# 2. Attaching the registry
############################################################################################

# Every `LoopAlgorithm` wrapper in the tree refers to the one registry of the whole tree.
@inline function attach_registry_to_tree(la::LoopAlgorithm, registry::R) where {R<:NameSpaceRegistry}
    plan = attach_registry_to_tree(getplan(la), registry)
    return _attach_registry(setfield(la, :plan, plan), registry)
end

@inline function attach_registry_to_tree(la::LA, registry::R) where {LA<:LoopSpec, R<:NameSpaceRegistry}
    funcs = tuplemap(getalgos(la)) do func
        func isa LoopSpec ? attach_registry_to_tree(func, registry) : func
    end
    return rebuild_loopalgorithm_funcs(la, funcs)
end

@inline function attach_registry_to_tree(fa::FA, registry::R) where {FA<:FinalizedAlgorithm, R<:NameSpaceRegistry}
    return finalstep(attach_registry_to_tree(inneralgorithm(fa), registry), finalfunction(fa))
end

############################################################################################
# 3. Wiring
############################################################################################

# Only `LoopAlgorithm` roots (and finalized ones) have plan wiring to resolve.
@inline resolve_plan_wiring(la, ::NameSpaceRegistry) = la

# Resolves the wiring of the whole tree (3.), then its scopes (4.).
@inline function resolve_plan_wiring(la::LoopAlgorithm, registry::NameSpaceRegistry)
    return setfield(la, :plan, _resolve_scopes(_resolve_plan_wiring_tree(getplan(la), registry, (;)), NoScope, ""))
end

# A finalized algorithm: resolve the loop inside, keep the final step.
@inline function resolve_plan_wiring(fa::FA, registry::NameSpaceRegistry) where {FA<:FinalizedAlgorithm}
    # The final step sees what outlives the steps (state, declared locals, inputs), not the last step's returns.
    return finalstep(resolve_plan_wiring(inneralgorithm(fa), registry), finalfunction(fa))
end

"""
Resolve a plan tree and inlay inherited global wiring into concrete children.

Runs once per plan on the plan as a value (`@nospecialize`, loops instead of closures): this function is compiled once,
and only the wiring helpers it calls compile for the registry and wiring types they get. `_resolve_plan_wiring_tree_typed`
(Typed.jl) is the inferred version.
"""
Base.@nospecializeinfer function _resolve_plan_wiring_tree(@nospecialize(la::AbstractPlan), @nospecialize(registry::NameSpaceRegistry), @nospecialize(inherited_global::NamedTuple))
    raw_wiring = getfield(la, :wiring)
    own_locals = getfield(raw_wiring, :locals)

    # Global wiring is grouped by resolved target namespace once per plan node.
    # Child buckets below receive the relevant global wiring already inlaid, so
    # `step!` never has to merge plan-global and child-specific wiring.
    own_global = _resolve_wiring_grouped(registry, getfield(raw_wiring, :global_wiring))
    combined_global = _merge_global_wiring(inherited_global, own_global)

    # Resolve nested plans first. Their own `PlanWiring` then becomes the
    # child-indexed value passed to that child during parent stepping.
    algos = getfield(la, :funcs)
    n = nfields(algos)
    funcs = Vector{Any}(undef, n)
    for i in 1:n
        child = getfield(algos, i)
        funcs[i] = child isa LoopSpec ? _resolve_plan_wiring_tree(child, registry, combined_global) : child
    end

    old_children = getfield(raw_wiring, :child_wiring)
    children = Vector{Any}(undef, n)
    for i in 1:n
        child = funcs[i]
        if child isa LoopSpec
            children[i] = getfield(child, :wiring)
            continue
        end
        target = _child_namespace_untyped(la, i)
        # Wires attached to this child (`WithWiring`) point at the child itself until now;
        # give them its namespace so they resolve like any route into it.
        bucket = _retarget_owner_routes(getfield(old_children, i), target)

        # Concrete children receive a single resolved `Wiring`: inherited global
        # wiring for their namespace, occluded by child-scoped routes.
        target_global = get(combined_global, target, Wiring())
        target_child = get(_resolve_wiring_grouped(registry, bucket), target, Wiring())
        children[i] = merge_wiring(target_global, target_child)
    end

    children_ = Tuple(children)
    W = Core.apply_type(PlanWiring, typeof(combined_global), typeof(children_), typeof(own_locals), NoScope, (; returns = (), owners = ()))
    return rebuild_plan(la, Tuple(funcs), W(combined_global, children_, own_locals))
end

#=
Wiring grouped by target: a named tuple from target namespace to the `Wiring` (routes and
shares) aimed at it, e.g. `(; Reader_1 = Wiring((route,), ()))`. Plan-wide wiring is kept in this
form so each child can take its group by its namespace.
=#

"""Append target-keyed `Wiring` groups for a tuple of namespace keys."""
@inline _append_wiring_group_keys(grouped::NamedTuple, ::Tuple{}, route_groups::NamedTuple, share_groups::NamedTuple) = grouped
@inline function _append_wiring_group_keys(grouped::NamedTuple, keys::Keys, route_groups::NamedTuple, share_groups::NamedTuple) where {Keys<:Tuple}
    key = first(keys)
    if key in propertynames(grouped)
        return _append_wiring_group_keys(grouped, Base.tail(keys), route_groups, share_groups)
    end
    bucket = Wiring(get(route_groups, key, ()), get(share_groups, key, ()))
    return _append_wiring_group_keys((; grouped..., key => bucket), Base.tail(keys), route_groups, share_groups)
end

"""Resolve a `Wiring` bucket and group it by target namespace."""
function _resolve_wiring_grouped(registry::NameSpaceRegistry, wiring::Wiring)
    share_groups = resolve_options(registry, shares(wiring)...)
    route_groups = resolve_options(registry, routes(wiring)...)
    grouped = _append_wiring_group_keys((;), propertynames(share_groups), route_groups, share_groups)
    return _append_wiring_group_keys(grouped, propertynames(route_groups), route_groups, share_groups)
end

"""Return already grouped global wiring unchanged."""
_resolve_wiring_grouped(::NameSpaceRegistry, grouped::NamedTuple) = grouped

"""Append merged global wiring for a tuple of namespace keys."""
@inline _append_merged_global_keys(merged::NamedTuple, ::Tuple{}, left::NamedTuple, right::NamedTuple) = merged
@inline function _append_merged_global_keys(merged::NamedTuple, keys::Keys, left::NamedTuple, right::NamedTuple) where {Keys<:Tuple}
    key = first(keys)
    if key in propertynames(merged)
        return _append_merged_global_keys(merged, Base.tail(keys), left, right)
    end
    bucket = merge_wiring(get(left, key, Wiring()), get(right, key, Wiring()))
    return _append_merged_global_keys((; merged..., key => bucket), Base.tail(keys), left, right)
end

"""Merge grouped global wiring, with right-side route aliases occluding left."""
function _merge_global_wiring(left::NamedTuple, right::NamedTuple)
    merged = _append_merged_global_keys((;), propertynames(left), left, right)
    return _append_merged_global_keys(merged, propertynames(right), left, right)
end

############################################################################################
# 4. Scopes
############################################################################################

"""
Make the name of the slot of a declared local (in `_declared_locals`) or a captured return (in `_captured_returns`).
One of the root plan keeps its name; one of a nested plan is suffixed with that plan's position, `x@1.2` (see `Scope`).
`path` is the plan's position, e.g. "1.2". Defined before `_resolve_scopes_typed` (Typed.jl), whose generator calls it.
"""
make_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)



"""
    _resolve_scopes(plan, Outer, path)

`plan` (with resolved wiring) with the scope of every node set (see `Scope`), and every route that reads a declared
local or a captured return pointed at its slot. `Outer` is the scope the node is in, `path` its position (`"2.1"`, `""`
for the root).

A node's scope is `Outer` with the node's own declared locals, and the returns of the calls directly in it that are
read somewhere in the node. An assignment to a name that is already visible writes that slot: a call in an inner node
that assigns a local or a return of an enclosing node updates it, as an assignment in a Julia loop body updates a
variable of the enclosing function.

Runs once per plan on plain values (names, tuples, types as values): compiled once, not per plan type.
`_resolve_scopes_typed` (Typed.jl) is the inferred version.
"""
Base.@nospecializeinfer function _resolve_scopes(@nospecialize(la::AbstractPlan), @nospecialize(Outer::Type{<:Scope}), path::String)
    wiring = getfield(la, :wiring)
    own_locals = getfield(wiring, :locals)
    outer_locals, outer_returns = Outer.parameters[1], Outer.parameters[2]
    locals = _scoped_names(outer_locals, fieldnames(typeof(own_locals)), path)
    read = _find_returns_read_in_plan(la)
    algos = getfield(la, :funcs)
    n = nfields(algos)
    captured = Symbol[]
    for i in 1:n
        for name in callable_return_names(typeof(getfield(algos, i)))
            name in read && !_has_name(locals, name) && !_has_name(outer_returns, name) &&
                !(name in captured) && push!(captured, name)
        end
    end
    Sc = Scope{locals, _scoped_names(outer_returns, Tuple(captured), path)}

    funcs = Vector{Any}(undef, n)
    for i in 1:n
        child = getfield(algos, i)
        funcs[i] = child isa LoopSpec ? _resolve_scopes(child, Sc, isempty(path) ? string(i) : string(path, ".", i)) : child
    end
    old_children = getfield(wiring, :child_wiring)
    children = Vector{Any}(undef, n)
    owners = Symbol[]
    for i in 1:n
        child = funcs[i]
        if child isa LoopSpec
            children[i] = getfield(child, :wiring)
            continue
        end
        children[i] = _scope_routes_to_storage(getfield(old_children, i), Sc)
        owner = _child_namespace_untyped(la, i)
        context_partition(Val(owner)) isa NamespacePartition && !(owner in owners) && push!(owners, owner)
    end
    resets = (; returns = Tuple(Symbol[make_storage_name(name, path) for name in captured]), owners = Tuple(owners))
    global_ = getfield(wiring, :global_wiring)
    children_ = Tuple(children)
    W = Core.apply_type(PlanWiring, typeof(global_), typeof(children_), typeof(own_locals), Sc, resets)
    return rebuild_plan(la, Tuple(funcs), W(global_, children_, own_locals))
end

"""The context name of child `i` of `plan`, as `plan_child_namespace`, read from the `Namespace` type as a value."""
Base.@nospecializeinfer function _child_namespace_untyped(@nospecialize(plan::AbstractPlan), i::Int)
    name = typeof(getfield(getfield(plan, :namespaces), i)).parameters[1]
    return name isa Symbol ? name : plan_child_namespace(plan, i)
end

"""`inherited` (`(; name = storage_name, ...)`) with `names`, declared in the plan at `path`, added or hiding the inherited ones."""
Base.@nospecializeinfer function _scoped_names(@nospecialize(inherited::NamedTuple), @nospecialize(names::Tuple), path::String)
    isempty(names) && return inherited
    keys_ = Symbol[fieldnames(typeof(inherited))...]
    slots = Symbol[getfield(inherited, i) for i in 1:nfields(inherited)]
    for name in names
        slot = make_storage_name(name, path)
        i = findfirst(==(name), keys_)
        isnothing(i) ? (push!(keys_, name); push!(slots, slot)) : (slots[i] = slot)
    end
    return NamedTuple{Tuple(keys_)}(Tuple(slots))
end

"""
Find every name read from the captured returns anywhere in a plan tree: the inputs of the calls in it, and the names its
routes read from `_captured_returns` (`_find_returns_read_by_route`).
"""
Base.@nospecializeinfer function _find_returns_read_in_plan(@nospecialize(la::AbstractPlan))
    names = Symbol[]
    algos = getfield(la, :funcs)
    children = getfield(getfield(la, :wiring), :child_wiring)
    for i in 1:nfields(algos)
        f = getfield(algos, i)
        if f isa LoopSpec
            _append_unique!(names, _find_returns_read_in_plan(f))
            continue
        end
        _append_unique!(names, callable_input_names(typeof(f)))
        for r in getfield(getfield(children, i), :routes)
            _append_unique!(names, _find_returns_read_by_route(r))
        end
    end
    return names
end
_has_name(@nospecialize(nt::NamedTuple), name::Symbol) = Base.fieldindex(typeof(nt), name, false) != 0
_append_unique!(names::Vector{Symbol}, @nospecialize(new)) = (for name in new; name in names || push!(names, name); end; names)
"""Find the names one route reads from the captured returns: none unless it reads from `_captured_returns`."""
_find_returns_read_by_route(::Route) = ()
_find_returns_read_by_route(r::Route{:_captured_returns}) = getvarnames(r)

"""
The wiring with every route that reads a declared local or a captured return (`Route(:_declared_locals => ..., :y => :x)`)
pointed at its slot in the scope `Sc` (`y`, or `y@1.2` for one declared or captured in a nested plan).
"""
_scope_routes_to_storage(wiring::Wiring, ::Type{Sc}) where {Sc<:Scope} =
    Wiring(map(r -> _route_to_storage(r, Sc), routes(wiring)), shares(wiring))
_route_to_storage(r::Route, ::Type) = r
_route_to_storage(r::Route{:_declared_locals, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_declared_locals, To, T, RT, _storage_names(scope_locals(Sc), V, "local", "declared"), A, Nothing, Nothing}()
_route_to_storage(r::Route{:_captured_returns, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_captured_returns, To, T, RT, _storage_names(scope_returns(Sc), V, "return", "captured by a call"), A, Nothing, Nothing}()

"""The storage names of `names` (a name, or a tuple of them) in `storage` (name ⇒ storage name); an error for one that is not there."""
_storage_names(storage::NamedTuple, names::Tuple, kind, how) = map(name -> _storage_names(storage, name, kind, how), names)
function _storage_names(storage::NamedTuple, name::Symbol, kind, how)
    haskey(storage, name) || construction_error("A route reads the ", kind, " `", name, "`, which is not ", how, " in this plan or an enclosing one.")
    return getproperty(storage, name)
end
