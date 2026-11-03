#=
Rule 1 of `_find_writable_fields` (see Writes.jl): an algorithm (`ProcessAlgorithm`, a `Callable` among them) writes the
fields of the payload its merge writes, read off the return type of `_leaf_payload`, which is built from the same pieces
as the algorithm's `_step!`.
=#

"""
The persistent fields one step of an algorithm can write: those of the payload its merge writes (`_leaf_payload`), read
off its type.
"""
@inline _find_writable_fields(algo::AlgoType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, session::SessionType, lifetime::LifetimeType) where {AlgoType<:ProcessAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, SessionType, LifetimeType} =
    RuntimeContextType <: ProcessContext ?
        _read_payload_fields(Core.Compiler.return_type(_leaf_payload, Tuple{AlgoType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType}), PersistentContextType) :
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

@inline @generated function _call_payload(contextview::SCV, retval::R) where {SCV<:SubContextView, R<:NamedTuple}
    names = _call_return_names(SCV, R)
    isempty(names) && return :((;))
    return :(@inline _build_merge_payload(contextview, $(_kept_returns_expr(names)), ReturnDemand{$names}()))
end

# What one step of a `Callable` writes: its view-visible returns.
@inline function _leaf_payload(ex::EX, lc::L, wiring::W, namespace::N) where {EX<:Callable,L,W,N}
    contextview = @inline _leaf_view(ex, lc, wiring, Namespace{:_captured_returns}())
    return @inline _call_payload(contextview, (@inline step!(ex, contextview)))
end
