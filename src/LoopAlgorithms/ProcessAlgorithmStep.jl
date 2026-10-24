"""
What one step of a leaf writes, as a named tuple: its updates (see `step_updates`), and its return value under
`RETURN_NAME` when a statement captures it (`y = Algo()` routes from it, so it is in the step's return demand).
"""
@inline _step_writes(retval, demand::ReturnDemand) = @inline _with_return((@inline step_updates(retval)), retval, demand)

# The return value is stored with its type in `retval` (a field of `retval`'s type, typed by `_type_as_inferred`), not the
# type of the one value returned this time.
@inline @generated function _with_return(updates::U, retval::R, ::ReturnDemand{Names}) where {U<:NamedTuple, R, Names}
    Names isa Tuple && RETURN_NAME in Names || return :updates
    V = R <: StepReturn ? fieldtype(R, :value) : R
    return :(merge(updates, NamedTuple{($(QuoteNode(RETURN_NAME)),), Tuple{$V}}(((@inline step_value(retval)),))))
end

"""
    _step_as_inferred(algo, contextview)

Step `algo` through `contextview` and return what it returned, typed as inference says `step!` returns it (see
`_type_as_inferred`). As Julia types a variable by everything that can be assigned to it, what a step writes into the
context is typed by the step's inferred return type, not by the type of the one value it returned this time.
"""
@inline function _step_as_inferred(algo::A, contextview::V) where {A, V}
    R = Core.Compiler.return_type(step!, Tuple{A, V})
    return @inline _type_as_inferred((@inline step!(algo, contextview)), R)
end

"""
The type of field `name` in `R`, an inferred named tuple type: concrete, bounded (`NamedTuple{names, T} where
T<:Tuple{...}`, read through its bound) or a `Union` of them. The union of its types in the members that have it;
`fallback` when a member has no field names to read (inference gave nothing to read it from).
"""
function _inferred_field_type(@nospecialize(R), name::Symbol, @nospecialize(fallback))
    types = Any[]
    for M in Base.uniontypes(R)
        names = _known_fieldnames(M)
        names === nothing && return fallback
        name in names && push!(types, fieldtype(M, name))
    end
    return isempty(types) ? fallback : Union{types...}
end

"""The field names of an inferred named tuple type `M` (concrete or bounded), or `nothing` when they are not known."""
function _known_fieldnames(@nospecialize(M))
    M <: NamedTuple || return nothing
    names = Base.unwrap_unionall(M).parameters[1]
    return names isa Tuple ? names : nothing
end

"""
`retval`, a `StepReturn`, with its value and its updates typed as in `R` (a `StepReturn` type or a `Union` of them), as
`_type_as_inferred` does for a named tuple.
"""
@inline @generated function _type_as_inferred(retval::StepReturn{V, StateUpdates{U}}, ::Type{R}) where {V, U, R}
    members = Base.uniontypes(R)
    all(M -> M <: StepReturn, members) || return :retval
    Value = Union{(fieldtype(M, :value) for M in members)...}
    Updates = Union{(fieldtype(fieldtype(M, :updates), :values) for M in members)...}
    TypedUpdates = NamedTuple{fieldnames(U), Tuple{map(name -> _inferred_field_type(Updates, name, fieldtype(U, name)), fieldnames(U))...}}
    Value === V && TypedUpdates === U && return :retval
    return :(StepReturn{$Value, StateUpdates{$TypedUpdates}}(getfield(retval, :value),
             StateUpdates{$TypedUpdates}($TypedUpdates(Tuple(getfield(getfield(retval, :updates), :values))))))
end

"""
    _type_as_inferred(retval, R)

`retval` with each field typed as in `R`, the inferred return type of the step that returned it: for a `Union` of named
tuples a field gets the union of its types in them, so a step that returns `(; x = nothing)` or `(; x = 1.0)` gives
`x::Union{Nothing,Float64}`. Returns `retval` itself when it already has those types, when it is not a named tuple, or
when `R` has no named tuple type to read them from.
"""
@inline @generated function _type_as_inferred(retval::NT, ::Type{R}) where {NT, R}
    NT <: NamedTuple || return :retval
    types = map(name -> _inferred_field_type(R, name, fieldtype(NT, name)), fieldnames(NT))
    Typed = NamedTuple{fieldnames(NT), Tuple{types...}}
    Typed === NT && return :retval
    return :($Typed(Tuple(retval)))
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
    retval = @inline _step_as_inferred(algo, contextview)
    return @inline _merge_step_return(contextview, retval, wiring, namespace)
end

"""The view a leaf step gets at its position in the plan: its namespace, and the shares and routes of its wiring."""
@inline _leaf_view(algo::A, lc::L, wiring::W, namespace::N) where {A,L<:LoopContext,W<:PlanWiringView,N<:Namespace} =
    @inline view(lc, algo, namespace; shares = (@inline shares(wiring)), routes = (@inline routes(wiring)))

# The persistent fields a leaf writes (see src/Context/Carried/Writes.jl).
@inline _find_writable_fields(algo::AlgoType, ::NoLoopCursor, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {AlgoType<:ProcessAlgorithm, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    @inline _find_leaf_writable_fields(algo, persistent_context, RuntimeContextType, wiring, namespace)

"""The persistent fields one step of an algorithm can write: those of the payload its merge writes, read off its type."""
@inline _find_leaf_writable_fields(algo::AlgoType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType) where {AlgoType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType} =
    RuntimeContextType <: ProcessContext ?
        _read_payload_fields(Core.Compiler.return_type(_leaf_payload, Tuple{AlgoType, _loop_context_type(PersistentContextType, RuntimeContextType, WiringViewType), WiringViewType, NamespaceType}), PersistentContextType) :
        _every_field(PersistentContextType)

"""
What one step of a leaf writes into the persistent context (see `_build_merge_payload`), built from the same pieces as its
`_step!`. Only its type is used.
"""
@inline function _leaf_payload(algo::A, lc::L, wiring::W, namespace::N) where {A,L,W,N}
    contextview = @inline _leaf_view(algo, lc, wiring, namespace)
    return @inline _step_payload(contextview, (@inline _step_as_inferred(algo, contextview)), wiring, namespace)
end

# As `_merge_step_return`: nothing is written when a step writes nothing.
@inline function _step_payload(contextview, retval, wiring::PlanWiringView, namespace::Namespace)
    demand = return_demand(wiring, namespace)
    return @inline _writes_payload(contextview, (@inline _step_writes(retval, demand)), demand)
end
@inline _writes_payload(contextview, ::NamedTuple{()}, demand::ReturnDemand) = (;)
@inline _writes_payload(contextview, writes::NamedTuple, demand::ReturnDemand) = @inline _build_merge_payload(contextview, writes, demand)
