#=
The inferred resolve: the same steps as `resolve` (Resolving.jl), written so that Julia infers the whole pipeline for
a concrete plan type and a caller that knows the plan type gets the resolved type at compile time. `resolve` does not
use it: inferring and compiling the pipeline as one function costs more for the first resolve of a plan than the
untyped steps, and gives nothing to a caller that gets `Any` from `resolve` anyway.

Steps 1 and 2 (registry, attaching it) are shared with `resolve`; steps 3 and 4 have typed versions here.

Preserved on purpose: nothing in the package calls this yet, but it stays, in this file apart from the untyped steps.
When an untyped step is changed (e.g. to compile less), its inferred twin here is kept.
=#

# Inferred: returns the concrete resolved type of `la`, which a caller that knows the plan type gets at compile time.
# One method per case: a method that calls itself with a growing type (plan -> `LoopAlgorithm{plan}`) is not inferred.
@inline _resolve_plan_typed(fa::FA) where {FA<:FinalizedAlgorithm} =
    finalstep(_resolve_plan_typed(inneralgorithm(fa)), finalfunction(fa))
@inline _resolve_plan_typed(la::LA) where {LA<:LoopSpec} = _resolve_plan_typed(LoopAlgorithm(la))
@inline function _resolve_plan_typed(la::LA) where {LA<:LoopAlgorithm}
    if isresolved(la)
        return la
    end

    registry, keyed_la = build_registry_and_key_plan(la)                    # 1. keys and namespaces
    keyed_la = _attach_registry(keyed_la, registry)                             # 2. share the registry
    plan = _resolve_wiring_typed(getplan(keyed_la), registry, (;))    # 3. routes, shares
    plan = _resolve_scopes_typed(plan, NoScope, Val(()))                        # 4. scopes
    return setoptions(setfield(keyed_la, :plan, plan), _collect_root_options(keyed_la))
end

"""
The inferred `_resolve_wiring` (Wiring.jl, which explains the steps): resolve a plan tree and inlay inherited
global wiring into concrete children.
"""
function _resolve_wiring_typed(la::LA, registry::NameSpaceRegistry, inherited_global::NamedTuple) where {LA<:AbstractPlan}
    raw_wiring = getwiring(la)
    own_locals = getfield(raw_wiring, :locals)
    own_global = _resolve_and_group_wiring(registry, global_wiring(raw_wiring))
    combined_global = _merge_global_wiring(inherited_global, own_global)
    funcs = _resolve_child_plans_typed(getalgos(la), registry, combined_global)

    resolved_children = ntuple(Val(length(funcs))) do i
        child = funcs[i]
        if child isa LoopSpec
            return getwiring(child)
        end
        target = plan_child_namespace(la, i)
        bucket = _retarget_owner_routes(getfield(child_wiring(raw_wiring), i), target)
        target_global = get(combined_global, target, Wiring())
        target_child = get(_resolve_and_group_wiring(registry, bucket), target, Wiring())
        resolved = merge_wiring(target_global, target_child)
        return resolved
    end

    return rebuild_plan_typed(la, funcs, PlanWiring(combined_global, resolved_children, own_locals))
end

# The children with the wiring of every nested plan resolved, the others as they are. Tuple recursion, not a closure in
# `ntuple`: a recursive call to `_resolve_wiring_typed` from inside that closure is not inferred.
@inline _resolve_child_plans_typed(::Tuple{}, registry::R, inherited_global::G) where {R<:NameSpaceRegistry, G<:NamedTuple} = ()
@inline _resolve_child_plans_typed(children::C, registry::R, inherited_global::G) where {C<:Tuple, R<:NameSpaceRegistry, G<:NamedTuple} =
    (_resolve_child_plan_typed(first(children), registry, inherited_global), _resolve_child_plans_typed(Base.tail(children), registry, inherited_global)...)
@inline _resolve_child_plan_typed(child::C, registry::R, inherited_global::G) where {C<:LoopSpec, R<:NameSpaceRegistry, G<:NamedTuple} =
    _resolve_wiring_typed(child, registry, inherited_global)
@inline _resolve_child_plan_typed(child::C, ::R, ::G) where {C, R<:NameSpaceRegistry, G<:NamedTuple} = child

"""
The inferred `_compute_node_scope` (Scopes.jl), from the plan node's type `LA`: compute its scope `Sc` and the slots
that entering the node clears, `(; returns, owners)`. Returns `(Sc, resets)` (see `PlanWiring`). `path` is the node's
position as child indices. Not specialized: it runs while code is generated and reads types only.
"""
Base.@nospecializeinfer function _compute_node_scope_typed(@nospecialize(LA::Type), @nospecialize(Outer::Type), @nospecialize(path::Tuple))
    at = join(path, ".")
    F = fieldtype(LA, :funcs)
    NS = fieldtype(LA, :namespaces)
    locals = _add_scoped_names(scope_locals(Outer), fieldnames(fieldtype(fieldtype(LA, :wiring), :locals)), at)
    read = _find_returns_read_in_plan_typed(LA)
    captured = Tuple(unique(Symbol[n for i in 1:fieldcount(F) for n in callable_return_names(fieldtype(F, i))
                                   if n in read && !_haskey_untyped(locals, n) && !_haskey_untyped(scope_returns(Outer), n)]))
    Sc = Scope{locals, _add_scoped_names(scope_returns(Outer), captured, at)}
    owners = Tuple(unique(Symbol[namesymbol(fieldtype(NS, i)) for i in 1:fieldcount(F)
                                 if !(fieldtype(F, i) <: LoopSpec) && context_partition(Val(namesymbol(fieldtype(NS, i)))) isa NamespacePartition]))
    return Sc, (; returns = map(name -> make_storage_name(name, at), captured), owners)
end

"""The inferred `_find_returns_read_in_plan` (Scopes.jl), from the plan's type `LA`."""
Base.@nospecializeinfer function _find_returns_read_in_plan_typed(@nospecialize(LA::Type))
    names = Symbol[]
    F = fieldtype(LA, :funcs)
    Children = fieldtype(fieldtype(LA, :wiring), :child_wiring)
    for i in 1:fieldcount(F)
        if fieldtype(F, i) <: LoopSpec
            _append_unique!(names, _find_returns_read_in_plan_typed(fieldtype(F, i)))
            continue
        end
        _append_unique!(names, callable_input_names(fieldtype(F, i)))
        for R in _route_types_from_wiring_type(fieldtype(Children, i))
            _append_unique!(names, _find_returns_read_by_route_typed(R))
        end
    end
    return names
end
"""The inferred `_find_returns_read_by_route` (Scopes.jl), from the route's type."""
_find_returns_read_by_route_typed(::Type{<:Route}) = ()
_find_returns_read_by_route_typed(R::Type{<:Route{:_captured_returns}}) = source_fieldnames(R)

"""
    _resolve_scopes_typed(plan, Outer, Val(path))

The inferred `_resolve_scopes` (Scopes.jl, which explains scopes); `path` is the node's position as child indices
(`(2, 1)`, `()` for the root). Generated: the scope goes into the plan's type, so it is computed from the types
(`_compute_node_scope_typed`) and the result is inferred.
"""
@generated function _resolve_scopes_typed(la::LA, ::Type{Outer}, ::Val{Path}) where {LA<:AbstractPlan, Outer<:Scope, Path}
    Sc, resets = _compute_node_scope_typed(LA, Outer, Path)
    F = fieldtype(LA, :funcs)
    children = [fieldtype(F, i) <: LoopSpec ? :(_resolve_scopes_typed(getalgo(la, $i), $Sc, $(Val((Path..., i))))) : :(getalgo(la, $i))
                for i in 1:fieldcount(F)]
    child_wirings = [fieldtype(F, i) <: LoopSpec ? :(getwiring(getfield(funcs, $i))) : :(_point_routes_at_storage_typed(getfield(child_wiring(wiring), $i), $Sc))
                     for i in 1:fieldcount(F)]
    return quote
        wiring = getwiring(la)
        funcs = ($(children...),)
        wirings = ($(child_wirings...),)
        return rebuild_plan_typed(la, funcs, PlanWiring(global_wiring(wiring), wirings, getfield(wiring, :locals), $Sc, $(Val(resets))))
    end
end

"""
The inferred `_point_routes_at_storage` (Scopes.jl): the wiring with every route that reads a declared local or a
captured return pointed at its slot in the scope `Sc`.
"""
_point_routes_at_storage_typed(wiring::Wiring, ::Type{Sc}) where {Sc<:Scope} =
    Wiring(map(r -> _point_route_at_storage_typed(r, Sc), routes(wiring)), shares(wiring))
_point_route_at_storage_typed(r::Route, ::Type) = r
_point_route_at_storage_typed(r::Route{:_declared_locals, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_declared_locals, To, T, RT, _look_up_storage_names_typed(scope_locals(Sc), V, "local", "declared"), A, Nothing, Nothing}()
_point_route_at_storage_typed(r::Route{:_captured_returns, To, T, RT, V, A}, ::Type{Sc}) where {To, T, RT, V, A, Sc} =
    Route{:_captured_returns, To, T, RT, _look_up_storage_names_typed(scope_returns(Sc), V, "return", "captured by a call"), A, Nothing, Nothing}()

"""The inferred `_look_up_storage_names` (Scopes.jl)."""
_look_up_storage_names_typed(storage::NamedTuple, names::Tuple, kind, how) = map(name -> _look_up_storage_names_typed(storage, name, kind, how), names)
function _look_up_storage_names_typed(storage::NamedTuple, name::Symbol, kind, how)
    haskey(storage, name) || construction_error("A route reads the ", kind, " `", name, "`, which is not ", how, " in this plan or an enclosing one.")
    return getproperty(storage, name)
end
