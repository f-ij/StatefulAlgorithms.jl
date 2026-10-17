"""
What one step of a leaf writes, as a named tuple: its updates (see `step_updates`), and its return value under
`RETURN_NAME` when a statement captures it (`y = Algo()` routes from it, so it is in the step's return demand).
"""
@inline _step_writes(retval, demand::ReturnDemand) = @inline _with_return((@inline step_updates(retval)), (@inline step_value(retval)), demand)

@inline @generated function _with_return(updates::U, value, ::ReturnDemand{Names}) where {U<:NamedTuple, Names}
    Names isa Tuple && RETURN_NAME in Names || return :updates
    return :(merge(updates, NamedTuple{($(QuoteNode(RETURN_NAME)),)}((value,))))
end

"""Merge what a leaf step returned through its view (see `_step_writes`)."""
@inline function _merge_step_return(contextview, retval, wiring::PlanWiringView, namespace::Namespace)
    demand = return_demand(wiring, namespace)
    return @inline _merge_writes(contextview, (@inline _step_writes(retval, demand)), demand)
end

@inline _merge_writes(contextview, ::NamedTuple{()}, demand::ReturnDemand) = @inline merge(contextview, nothing)
@inline _merge_writes(contextview, writes::NamedTuple, demand::ReturnDemand) = @inline merge(contextview, writes, demand)

"""
Step a raw `ProcessAlgorithm` child through its resolved loop namespace.

Resolved loop plans store raw algorithm values and carry identity separately in
`Namespace{Name}`. The wiring argument is always a `PlanWiringView` in the
current loop runtime, so route/share lookup and return-demand analysis both read
through that view.
"""
@inline function _step!(
    algo::A,
    ::NoLoopCursor,
    lc::L,
    wiring::W,
    namespace::Namespace{Name},
    process::P,
    lifetime::LT,
) where {A<:ProcessAlgorithm,L<:LoopContext,W<:PlanWiringView,Name,P<:AbstractProcess,LT<:Lifetime}
    return @inline _step!(algo, lc, wiring, namespace, process, lifetime)
end

@inline function _step!(
    algo::A,
    lc::L,
    wiring::W,
    namespace::Namespace{Name},
    process::P,
    lifetime::LT,
) where {A<:ProcessAlgorithm,L<:LoopContext,W<:PlanWiringView,Name,P<:AbstractProcess,LT<:Lifetime}
    contextview = @inline _leaf_view(algo, lc, wiring, namespace)
    retval = @inline step!(algo, contextview)
    return @inline _merge_step_return(contextview, retval, wiring, namespace)
end

"""The view a leaf step gets at its position in the plan: its namespace, and the shares and routes of its wiring."""
@inline _leaf_view(algo::A, lc::L, wiring::W, namespace::N) where {A,L<:LoopContext,W<:PlanWiringView,N<:Namespace} =
    @inline view(lc, algo, namespace; sharedcontexts = (@inline shares(wiring)), sharedvars = (@inline routes(wiring)))

# The persistent fields a leaf writes (see src/Context/Carried/Writes.jl).
@inline _writes(algo::AlgoType, ::NoLoopCursor, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {AlgoType<:ProcessAlgorithm, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    @inline _leaf_writes(algo, persistent_context, RuntimeContextType, wiring, namespace)

"""The persistent fields one step of an algorithm can write: those of the payload its merge writes, read off its type."""
@inline _leaf_writes(algo::AlgoType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType) where {AlgoType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType} =
    RuntimeContextType <: ProcessContext ?
        _payload_writes(Core.Compiler.return_type(_leaf_payload, Tuple{AlgoType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType}), PersistentContextType) :
        _every_field(PersistentContextType)

"""
What one step of a leaf writes into the persistent context (see `_build_merge_payload`), built from the same pieces as its
`_step!`. Only its type is used.
"""
@inline function _leaf_payload(algo::A, lc::L, wiring::W, namespace::N) where {A,L,W,N}
    contextview = @inline _leaf_view(algo, lc, wiring, namespace)
    return @inline _step_payload(contextview, (@inline step!(algo, contextview)), wiring, namespace)
end

# As `_merge_step_return`: nothing is written when a step writes nothing.
@inline function _step_payload(contextview, retval, wiring::PlanWiringView, namespace::Namespace)
    demand = return_demand(wiring, namespace)
    return @inline _writes_payload(contextview, (@inline _step_writes(retval, demand)), demand)
end
@inline _writes_payload(contextview, ::NamedTuple{()}, demand::ReturnDemand) = (;)
@inline _writes_payload(contextview, writes::NamedTuple, demand::ReturnDemand) = @inline _build_merge_payload(contextview, writes, demand)
