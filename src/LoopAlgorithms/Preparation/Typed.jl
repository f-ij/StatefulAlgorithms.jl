#=
The inferred resolve: the same steps as `resolve` (Constructor.jl), written so that Julia infers the whole pipeline for
a concrete plan type and a caller that knows the plan type gets the resolved type at compile time. `resolve` does not
use it: inferring and compiling the pipeline as one function costs more for the first resolve of a plan than the
untyped steps, and gives nothing to a caller that gets `Any` from `resolve` anyway.

Steps 1 and 2 (registry, attaching it) are shared with `resolve`; steps 3 and 4 have typed versions here.
=#

# Inferred: returns the concrete resolved type of `la`, which a caller that knows the plan type gets at compile time.
# One method per case: a method that calls itself with a growing type (plan -> `LoopAlgorithm{plan}`) is not inferred.
@inline _resolve_typed(fa::FA) where {FA<:FinalizedAlgorithm} =
    finalstep(_resolve_typed(inneralgorithm(fa)), finalfunction(fa))
@inline _resolve_typed(la::LA) where {LA<:LoopSpec} = _resolve_typed(LoopAlgorithm(la))
@inline function _resolve_typed(la::LA) where {LA<:LoopAlgorithm}
    if isresolved(la)
        return la
    end

    registry, keyed_la = setup_registry_and_keyed_algos(la)   # 1. keys and namespaces
    keyed_la = _attach_registry(keyed_la, registry)            # 2. share the registry
    plan = _resolve_plan_wiring_tree_typed(getplan(keyed_la), registry, (;))   # 3. routes, shares
    keyed_la = setfield(keyed_la, :plan, _resolve_scopes_typed(plan, NoScope, Val(())))   # 4. scopes
    # The `RootOption`s of the plan tree stay on the root wrapper.
    return setoptions(keyed_la, _root_options(la))
end

"""
The inferred `_resolve_plan_wiring_tree`: resolve a plan tree and inlay inherited global wiring into concrete children.
"""
function _resolve_plan_wiring_tree_typed(la::LA, registry::NameSpaceRegistry, inherited_global::NamedTuple) where {LA<:AbstractPlan}
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
    # A new name, not `la = ...`: `la` is captured by the closure below, and a captured variable that is reassigned
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
# `ntuple`: a recursive call to `_resolve_plan_wiring_tree_typed` from inside that closure is not inferred.
@inline _resolve_child_plans(::Tuple{}, registry::R, inherited_global::G) where {R<:NameSpaceRegistry, G<:NamedTuple} = ()
@inline _resolve_child_plans(children::C, registry::R, inherited_global::G) where {C<:Tuple, R<:NameSpaceRegistry, G<:NamedTuple} =
    (_resolve_child_plan(first(children), registry, inherited_global), _resolve_child_plans(Base.tail(children), registry, inherited_global)...)
@inline _resolve_child_plan(child::C, registry::R, inherited_global::G) where {C<:LoopSpec, R<:NameSpaceRegistry, G<:NamedTuple} =
    _resolve_plan_wiring_tree_typed(child, registry, inherited_global)
@inline _resolve_child_plan(child::C, ::R, ::G) where {C, R<:NameSpaceRegistry, G<:NamedTuple} = child

"""
Compute the scope `Sc` of a plan node of type `LA`, and the slots that entering the node clears, `(; returns, owners)`.
Returns `(Sc, resets)` (see `_resolve_scopes_typed`, `PlanWiring`). `Outer` is the scope the node is in, `path` its
position as child indices. Not specialized: it runs while code is generated and reads types only.
"""
Base.@nospecializeinfer function _compute_node_scope(@nospecialize(LA::Type), @nospecialize(Outer::Type), @nospecialize(path::Tuple))
    at = join(path, ".")
    F = fieldtype(LA, :funcs)
    NS = fieldtype(LA, :namespaces)
    locals = _scoped_names(scope_locals(Outer), fieldnames(fieldtype(fieldtype(LA, :wiring), :locals)), at)
    read = _find_returns_read_in_plan_type(LA)
    captured = Tuple(unique(Symbol[n for i in 1:fieldcount(F) for n in callable_return_names(fieldtype(F, i))
                                   if n in read && !haskey(locals, n) && !haskey(scope_returns(Outer), n)]))
    Sc = Scope{locals, _scoped_names(scope_returns(Outer), captured, at)}
    owners = Tuple(unique(Symbol[namesymbol(fieldtype(NS, i)) for i in 1:fieldcount(F)
                                 if !(fieldtype(F, i) <: LoopSpec) && context_partition(Val(namesymbol(fieldtype(NS, i)))) isa NamespacePartition]))
    return Sc, (; returns = map(name -> make_storage_name(name, at), captured), owners)
end

"""
Find every name read from the captured returns anywhere in a plan tree (type): the inputs of the calls in it, and the
names its routes read from `_captured_returns` (`_find_returns_read_by_route`).
"""
Base.@nospecializeinfer function _find_returns_read_in_plan_type(@nospecialize(LA::Type))
    names = ()
    F = fieldtype(LA, :funcs)
    Children = fieldtype(fieldtype(LA, :wiring), :child_wiring)
    for i in 1:fieldcount(F)
        if fieldtype(F, i) <: LoopSpec
            names = _append_route_demand_names(names, _find_returns_read_in_plan_type(fieldtype(F, i)))
            continue
        end
        names = _append_route_demand_names(names, callable_input_names(fieldtype(F, i)))
        for R in _route_types_from_wiring_type(fieldtype(Children, i))
            names = _append_route_demand_names(names, _find_returns_read_by_route(R))
        end
    end
    return names
end
"""Find the names one route (type) reads from the captured returns: none unless it reads from `_captured_returns`."""
_find_returns_read_by_route(::Type{<:Route}) = ()
_find_returns_read_by_route(R::Type{<:Route{:_captured_returns}}) = getvarnames(R)

"""
    _resolve_scopes_typed(plan, Outer, Val(path))

`plan` (with resolved wiring) with the scope of every node set (see `Scope`), and every route that reads a declared
local or a captured return pointed at its slot. `Outer` is the scope the node is in, `path` its position as child
indices (`(2, 1)`, `()` for the root).

A node's scope is `Outer` with the node's own declared locals, and the returns of the calls directly in it that are
read somewhere in the node. An assignment to a name that is already visible writes that slot: a call in an inner node
that assigns a local or a return of an enclosing node updates it, as an assignment in a Julia loop body updates a
variable of the enclosing function.

The inferred `_resolve_scopes`. Generated: the scope goes into the plan's type, so it is computed from the types
(`_compute_node_scope`) and the result is inferred.
"""
@generated function _resolve_scopes_typed(la::LA, ::Type{Outer}, ::Val{Path}) where {LA<:AbstractPlan, Outer<:Scope, Path}
    Sc, resets = _compute_node_scope(LA, Outer, Path)
    F = fieldtype(LA, :funcs)
    children = [fieldtype(F, i) <: LoopSpec ? :(_resolve_scopes_typed(getalgo(la, $i), $Sc, $(Val((Path..., i))))) : :(getalgo(la, $i))
                for i in 1:fieldcount(F)]
    child_wirings = [fieldtype(F, i) <: LoopSpec ? :(getwiring(getfield(funcs, $i))) : :(_scope_routes_to_storage(getfield(child_wiring(wiring), $i), $Sc))
                     for i in 1:fieldcount(F)]
    return quote
        wiring = getwiring(la)
        funcs = ($(children...),)
        rebuilt = rebuild_loopalgorithm_funcs(la, funcs)
        wirings = ($(child_wirings...),)
        return setfield(rebuilt, :wiring, PlanWiring(global_wiring(wiring), wirings, getfield(wiring, :locals), $Sc, $(Val(resets))))
    end
end
