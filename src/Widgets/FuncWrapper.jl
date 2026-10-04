export FuncWrapper

"""Slot of a literal argument value in a `Callable`'s `values`."""
struct ValueRef{index, T} end
@inline _valueref_index(::ValueRef{index, T}) where {index, T} = index

"""
Endpoint of a route that belongs to one plan child (a `WithWiring` wire): matched to its
child when the plan is built, and pointed at that child's namespace at resolve.
"""
struct OwnerMatcher <: AbstractMatcher{nothing} end

"""
    _call_return_names(SCV, R, DemandNames)

Split the return names of a `Callable` (the field names of `R`): names visible in its view (`SCV`) are real
state/writeback targets; the others are temporary runtime outputs for later DSL statements, kept when demanded.
"""
function _call_return_names(SCV::Type, R::Type, DemandNames)
    view_names = Symbol[]
    runtime_names = Symbol[]
    for name in fieldnames(R)
        location, _ = _compute_location(SCV, name)
        if isnothing(location)
            (DemandNames === :all || name in DemandNames) && push!(runtime_names, name)
        else
            push!(view_names, name)
        end
    end
    return view_names, runtime_names
end

# The persistent fields a `Callable` writes (see src/Context/Carried/Writes.jl): its view-visible returns.
@inline function _leaf_payload(ex::EX, context::C, runtimecontext::RC, wiring::W, namespace::N) where {EX<:Callable,C,RC,W,N}
    contextview = @inline _leaf_view(ex, context, runtimecontext, wiring, Namespace{:_runtime}())
    return @inline _call_payload(contextview, (@inline step!(ex, contextview)))
end

@inline _call_payload(contextview::SCV, ::Nothing) where {SCV<:SubContextView} = (;)
@inline @generated function _call_payload(contextview::SCV, retval::R) where {SCV<:SubContextView, R<:NamedTuple}
    view_names, _ = _call_return_names(SCV, R, ())
    isempty(view_names) && return :((;))
    view_expr = Expr(:tuple, Expr(:parameters, (Expr(:kw, name, :(getproperty(retval, $(QuoteNode(name))))) for name in view_names)...))
    return :(@inline _merge_payload(contextview, $view_expr, ReturnDemand{$(Tuple(view_names))}()))
end

"""
Merge a `Callable` return into the correct runtime target.

Outputs whose names already resolve in the wrapper view are routed/shared/local
writebacks and should be merged through `SubContextView`. New output names are
DSL temporaries and remain in `ProcessContext._runtime` for later statements.
"""
@inline @generated function merge_call_return(
    contextview::SCV,
    context::C,
    runtimecontext::RC,
    retval::R,
    ) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext, R<:NamedTuple}
    demand_type = ReturnDemand{fieldnames(R)}
    return :(merge_call_return(contextview, context, runtimecontext, retval, $demand_type()))
end

@inline @generated function merge_call_return(
    contextview::SCV,
    context::C,
    runtimecontext::RC,
    retval::R,
    demand::ReturnDemand{DemandNames},
) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext, R<:NamedTuple, DemandNames}
    view_names, runtime_names = _call_return_names(SCV, R, DemandNames)

    view_expr = Expr(:tuple, Expr(:parameters, (
        Expr(:kw, name, :(getproperty(retval, $(QuoteNode(name)))))
        for name in view_names
    )...))
    runtime_expr = Expr(:tuple, Expr(:parameters, (
        Expr(:kw, name, :(getproperty(retval, $(QuoteNode(name)))))
        for name in runtime_names
    )...))

    view_merge_expr = if isempty(view_names)
        :((context, runtimecontext))
    else
        :(@inline merge(contextview, $view_expr))
    end

    runtime_merge_expr = if isempty(runtime_names)
        :(merged_context, merged_runtimecontext)
    else
        :(merged_context, (@inline merge_runtime_return(merged_runtimecontext, $runtime_expr)))
    end

    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        merged_context, merged_runtimecontext = $view_merge_expr
        return $runtime_merge_expr
    end
end

"""
Treat a call with no return value as a pure side-effecting step.
"""
@inline merge_call_return(contextview::SCV, context::C, runtimecontext::RC, ::Nothing) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext} = context, runtimecontext
@inline merge_call_return(contextview::SCV, context::C, runtimecontext::RC, ::Nothing, demand::ReturnDemand) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext} = context, runtimecontext

"""
    FuncWrapper(f, inputs, outputs[, kwargs])

Deprecated: use [`Callable`](@ref)`(f, args, kwargs, returns)`. Same arguments: `inputs`
are plan names or literal values, `outputs` a tuple of names, `kwargs` a named tuple of
keyword => plan name or literal (or a tuple of names, meaning `name = name`).
"""
function FuncWrapper(f, inputs, outputs::Tuple{Vararg{Symbol}}, kwargs = (;), display...)
    Base.depwarn("`FuncWrapper(f, inputs, outputs, kwargs)` is deprecated, use `Callable(f, args, kwargs, returns)`.", :FuncWrapper)
    return _callable_from_call(f, inputs, outputs, kwargs)
end

"""The `Callable` for a call written as `outputs = f(inputs...; kwargs...)` (DSL and `FuncWrapper` form)."""
function _callable_from_call(f, inputs, outputs::Tuple{Vararg{Symbol}}, kwargs = (;))
    kwargs = kwargs isa Tuple{Vararg{Symbol}} ? NamedTuple{kwargs}(kwargs) : kwargs
    input(x) = x isa QuoteNode ? Literal(x.value) : x
    returns = length(outputs) == 0 ? () : length(outputs) == 1 ? only(outputs) : outputs
    return Callable(f, map(input, Tuple(inputs)), map(input, kwargs), returns)
end
