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
=#

"""
Materialize a loop algorithm for context construction.

This wraps bare plan nodes in a concrete `LoopAlgorithm`, builds a registry,
keys the child algorithms, resolves the route/share wiring against that
registry, and collects the `RootOption`s of the plan tree. The returned value is always a runtime wrapper unless the input was a
`FinalizedAlgorithm`, in which case the finalized outer shape is preserved and
its inner loop is materialized.

Plans with `Unique` handles are resolved with their random ids normalized, so the typed part is compiled once per
plan shape (NormalizeIds.jl); other plans go straight to the typed body, compiled once per plan type.
"""
Base.@nospecializeinfer function resolve(@nospecialize(la::LoopSpec))
    # Untyped entry: compiled once, not per plan type (a new set of `Unique` ids is a new plan type). The trait is
    # computed at run time, then the dispatch picks the path.
    return _resolve_by_trait(_unique_handles_trait(la), la)
end

# Inferred: returns the concrete resolved type of `la`, which a caller that knows the plan type gets at compile time.
# One method per case: a method that calls itself with a growing type (plan -> `LoopAlgorithm{plan}`) is not inferred.
# `keep_root_returns`: the plan has a final step, which reads every return of the root's calls (see `_resolve_scopes`).
@inline _resolve_typed(fa::FA, ::Val{K} = Val(false)) where {FA<:FinalizedAlgorithm, K} =
    finalstep(_resolve_typed(inneralgorithm(fa), Val(true)), finalfunction(fa))
@inline _resolve_typed(la::LA, keep_root_returns::Val{K} = Val(false)) where {LA<:LoopSpec, K} =
    _resolve_typed(LoopAlgorithm(la), keep_root_returns)
@inline function _resolve_typed(la::LA, keep_root_returns::Val{K} = Val(false)) where {LA<:LoopAlgorithm, K}
    if isresolved(la)
        return la
    end

    registry, keyed_la = setup_registry_and_keyed_algos(la)   # 1. keys and namespaces
    keyed_la = attach_registry_to_tree(keyed_la, registry)     # 2. share the registry
    keyed_la = resolve_plan_wiring(keyed_la, registry, keep_root_returns)   # 3. and 4. routes, shares, scopes
    # The `RootOption`s of the plan tree stay on the root wrapper.
    return setoptions(keyed_la, _root_options(la))
end

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

@inline add_algo_tuple_to_registry(registry::R, ::Tuple{}, ::Tuple{}) where {R<:NameSpaceRegistry} = registry, (), ()

"""Plain function calls have no state or identity: not registered, all in their `fixed_namespace`."""
@inline add_algo_to_registry(registry::R, ex::EX, multiplier) where {R<:NameSpaceRegistry, EX<:Callable} =
    registry, ex, Namespace{fixed_namespace(ex)}()

"""
    add_algo_tuple_to_registry(registry, funcs, multipliers) -> (registry, raw_funcs, namespaces)

Register the children of one plan, first to last, each with its multiplier. Returns the registry with the children
added, the children as the plan stores them afterwards (a plain algorithm without its identifiable wrapper, or a
nested plan whose own children are registered too), and per child its context name as a `Namespace` type
(`Namespace{:Counter_1}`, or `Namespace{nothing}` for a nested plan).
"""
@inline function add_algo_tuple_to_registry(registry::R, funcs::F, multipliers::M) where {R<:NameSpaceRegistry, F<:Tuple, M<:Tuple}
    return _add_algo_tuple_in_order(registry, funcs, multipliers)
end

"""Add the children one by one, first to last; returns the same three values as `add_algo_tuple_to_registry`."""
@inline function _add_algo_tuple_in_order(registry::R, funcs::F, multipliers::M) where {R<:NameSpaceRegistry, F<:Tuple, M<:Tuple}
    # Written as recursion over the front of the tuple that adds the last child to the registry it gets back, so that
    # the registry's type stays known: it grows with every child, and recursing over the tail instead (passing the
    # growing registry down as an argument) makes Julia give up and use plain `NameSpaceRegistry`. Here the arguments
    # only get shorter, which works for any number of children.
    reg, raws, names = _add_algo_tuple_in_order(registry, Base.front(funcs), Base.front(multipliers))
    reg, raw, name = add_algo_to_registry(reg, last(funcs), last(multipliers))
    return reg, (raws..., raw), (names..., name)
end
@inline _add_algo_tuple_in_order(registry::R, ::Tuple{}, ::Tuple{}) where {R<:NameSpaceRegistry} = registry, (), ()

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

# An algorithm or state: the registry assigns its key. The plan keeps the raw algorithm and the
# key as its namespace, so the plan's types do not depend on identity wrappers.
@inline function add_algo_to_registry(registry::R, algo::A, multiplier) where {R<:NameSpaceRegistry, A}
    registry, keyed_algo = add(registry, algo, multiplier)
    return registry, getalgo(keyed_algo), Namespace{getkey(keyed_algo)}()
end

# Replace the children of a plan, of the plan inside a wrapper, or inside a finalized algorithm.
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

# Only `LoopAlgorithm` roots (and finalized ones) have plan wiring to resolve.
@inline resolve_plan_wiring(la, ::NameSpaceRegistry) = la

@inline function resolve_plan_wiring(la::LoopAlgorithm, registry::NameSpaceRegistry, keep_root_returns::Val{K} = Val(false)) where {K}
    return setfield(la, :plan, _resolve_scopes(_resolve_plan_wiring_tree(getplan(la), registry, (;)), NoScope, Val(()), keep_root_returns))
end

"""
Resolve a plan tree and inlay inherited global wiring into concrete children.
"""
function _resolve_plan_wiring_tree(la::LA, registry::NameSpaceRegistry, inherited_global::NamedTuple) where {LA<:AbstractPlan}
    raw_wiring = getwiring(la)
    own_locals = getfield(raw_wiring, :locals)

    # Global wiring is grouped by resolved target namespace once per plan node.
    # Child buckets below receive the relevant global wiring already inlaid, so
    # `step!` never has to merge plan-global and child-specific wiring.
    own_global = _resolve_wiring_grouped(registry, global_wiring(raw_wiring))
    combined_global = _merge_global_wiring(inherited_global, own_global)

    # Resolve nested plans first. Their own `PlanWiring` then becomes the
    # child-indexed value passed to that child during parent stepping.
    funcs = _resolve_child_plans(getalgos(la), registry, combined_global)
    # A new name, not `la = ...`: `la` is captured by the closure above, and a captured variable that is reassigned
    # is boxed (`Core.Box`), which makes every use of it uninferable.
    rebuilt = rebuild_loopalgorithm_funcs(la, funcs)

    resolved_children = ntuple(Val(length(funcs))) do i
        child = funcs[i]
        if child isa LoopSpec
            return getwiring(child)
        end
        target = plan_child_namespace(rebuilt, i)
        # Wires attached to this child (`WithWiring`) point at the child itself until now;
        # give them its namespace so they resolve like any route into it.
        bucket = _retarget_owner_routes(getfield(child_wiring(raw_wiring), i), target)

        # Concrete children receive a single resolved `Wiring`: inherited global
        # wiring for their namespace, occluded by child-scoped routes.
        target_global = get(combined_global, target, Wiring())
        target_child = get(_resolve_wiring_grouped(registry, bucket), target, Wiring())
        resolved = merge_wiring(target_global, target_child)
        return resolved
    end

    return setfield(rebuilt, :wiring, PlanWiring(combined_global, resolved_children, own_locals))
end

# The children with the wiring of every nested plan resolved, the others as they are. Tuple recursion, not a closure in
# `ntuple`: a recursive call to `_resolve_plan_wiring_tree` from inside that closure is not inferred.
@inline _resolve_child_plans(::Tuple{}, registry::R, inherited_global::G) where {R<:NameSpaceRegistry, G<:NamedTuple} = ()
@inline _resolve_child_plans(children::C, registry::R, inherited_global::G) where {C<:Tuple, R<:NameSpaceRegistry, G<:NamedTuple} =
    (_resolve_child_plan(first(children), registry, inherited_global), _resolve_child_plans(Base.tail(children), registry, inherited_global)...)
@inline _resolve_child_plan(child::C, registry::R, inherited_global::G) where {C<:LoopSpec, R<:NameSpaceRegistry, G<:NamedTuple} =
    _resolve_plan_wiring_tree(child, registry, inherited_global)
@inline _resolve_child_plan(child::C, ::R, ::G) where {C, R<:NameSpaceRegistry, G<:NamedTuple} = child

"""
The scope of a plan node of type `LA` and the slots entering it makes unset, `(Sc, (; returns, owners))` (see
`_resolve_scopes`, `PlanWiring`). `Outer` is the scope the node is in, `path` its position as child indices.
"""
function _node_scope(::Type{LA}, ::Type{Outer}, path::Tuple, keep_returns::Bool) where {LA<:AbstractPlan, Outer<:Scope}
    at = join(path, ".")
    F = fieldtype(LA, :funcs)
    NS = fieldtype(LA, :namespaces)
    locals = _scoped_names(scope_locals(Outer), fieldnames(fieldtype(fieldtype(LA, :wiring), :locals)), at)
    read = _return_reads(LA)
    captured = Tuple(unique(Symbol[n for i in 1:fieldcount(F) for n in callable_return_names(fieldtype(F, i))
                                   if (keep_returns || n in read) && !haskey(locals, n) && !haskey(scope_returns(Outer), n)]))
    Sc = Scope{locals, _scoped_names(scope_returns(Outer), captured, at)}
    owners = Tuple(unique(Symbol[namesymbol(fieldtype(NS, i)) for i in 1:fieldcount(F)
                                 if !(fieldtype(F, i) <: LoopSpec) && context_partition(Val(namesymbol(fieldtype(NS, i)))) isa NamespacePartition]))
    return Sc, (; returns = map(name -> make_storage_name(name, at), captured), owners)
end

"""
Make the name of the slot of a declared local (in `_declared_locals`) or a captured return (in `_captured_returns`).
One of the root plan keeps its name; one of a nested plan is suffixed with that plan's position, `x@1.2` (see `Scope`).
`path` is the plan's position, e.g. "1.2". Defined before `_resolve_scopes`, whose generator calls it.
"""
make_storage_name(name::Symbol, path::String) = isempty(path) ? name : Symbol(name, "@", path)

"""`inherited` (`(; name = storage_name, ...)`) with `names`, declared in the plan at `path`, added or hiding the inherited ones."""
_scoped_names(inherited::NamedTuple, names::Tuple, path::String) =
    merge(inherited, NamedTuple{names}(map(name -> make_storage_name(name, path), names)))

"""Every name read from the captured returns in a plan tree (type): by the calls in it, and by its routes from `_captured_returns`."""
function _return_reads(::Type{LA}) where {LA<:AbstractPlan}
    names = ()
    F = fieldtype(LA, :funcs)
    Children = fieldtype(fieldtype(LA, :wiring), :child_wiring)
    for i in 1:fieldcount(F)
        if fieldtype(F, i) <: LoopSpec
            names = _append_route_demand_names(names, _return_reads(fieldtype(F, i)))
            continue
        end
        names = _append_route_demand_names(names, callable_input_names(fieldtype(F, i)))
        for R in _route_types_from_wiring_type(fieldtype(Children, i))
            names = _append_route_demand_names(names, _returns_read_by(R))
        end
    end
    return names
end
_returns_read_by(::Type{<:Route}) = ()
_returns_read_by(R::Type{<:Route{:_captured_returns}}) = getvarnames(R)

"""
    _resolve_scopes(plan, Outer, Val(path), Val(keep_returns))

`plan` (with resolved wiring) with the scope of every node set (see `Scope`), and every route that reads a declared
local or a captured return pointed at its slot. `Outer` is the scope the node is in, `path` its position as child
indices (`(2, 1)`, `()` for the root).

A node's scope is `Outer` with the node's own declared locals, and the returns of the calls directly in it that are
read somewhere in the node (all of them with `keep_returns`: the root of a plan with a final step, which reads them). An assignment to a name that is already visible writes that slot: a call in an inner node
that assigns a local or a return of an enclosing node updates it, as an assignment in a Julia loop body updates a
variable of the enclosing function.

Generated: the scope goes into the plan's type, so it is computed from the types (`_node_scope`) and the result is inferred.
"""
@generated function _resolve_scopes(la::LA, ::Type{Outer}, ::Val{Path}, ::Val{KeepReturns}) where {LA<:AbstractPlan, Outer<:Scope, Path, KeepReturns}
    Sc, resets = _node_scope(LA, Outer, Path, KeepReturns)
    F = fieldtype(LA, :funcs)
    funcs = [fieldtype(F, i) <: LoopSpec ? :(_resolve_scopes(getalgo(la, $i), $Sc, $(Val((Path..., i))), Val(false))) : :(getalgo(la, $i))
             for i in 1:fieldcount(F)]
    children = [fieldtype(F, i) <: LoopSpec ? :(getwiring(getfield(funcs, $i))) : :(_scope_routes_to_storage(getfield(child_wiring(wiring), $i), $Sc))
                for i in 1:fieldcount(F)]
    return quote
        wiring = getwiring(la)
        funcs = ($(funcs...),)
        rebuilt = rebuild_loopalgorithm_funcs(la, funcs)
        children = ($(children...),)
        return setfield(rebuilt, :wiring, PlanWiring(global_wiring(wiring), children, getfield(wiring, :locals), $Sc, $(Val(resets))))
    end
end

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

# A finalized algorithm: resolve the loop inside, keep the final step.
@inline function resolve_plan_wiring(fa::FA, registry::NameSpaceRegistry) where {FA<:FinalizedAlgorithm}
    # The final step reads the root scope after the last step: every return of the root's calls.
    return finalstep(resolve_plan_wiring(inneralgorithm(fa), registry, Val(true)), finalfunction(fa))
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
