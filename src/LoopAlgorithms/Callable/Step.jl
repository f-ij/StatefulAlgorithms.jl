_input_var(name::Symbol) = Symbol("in#", name)
_output_var(name::Symbol) = Symbol("out#", name)
_arg_expr(item::Symbol) = _input_var(item)
_arg_expr(item::Splat) = Expr(:..., _input_var(splatname(item)))
_arg_expr(::ValueRef{index}) where {index} = :(getfield(getfield(ex, :values), $index))
_kwarg_expr(item::Splat) = Expr(:..., _input_var(splatname(item)))
_kwarg_expr(item::Tuple) = Expr(:kw, first(item), _arg_expr(last(item)))

"""Read the input names from `view`, call the function, and return the outputs by plan name."""
@inline @generated function step!(ex::Callable{F, Args, Kwargs, Returns}, view) where {F, Args, Kwargs, Returns}
    input_names = callable_input_names(ex)
    reads = [:($(_input_var(n)) = @inline getproperty(view, $(QuoteNode(n)))) for n in input_names]
    call = Expr(:call, :(getfield(ex, :f)), Expr(:parameters, map(_kwarg_expr, Kwargs)...), map(_arg_expr, Args)...)

    kind, names, types = _returns_parts(Returns)
    kind === :none && return quote
        $(reads...)
        $call
        return (;)
    end
    plan_names = callable_return_names(ex)
    assign = if kind === :single
        :($(_output_var(only(plan_names))) = $call)
    elseif kind === :unpack
        lhs = Expr(:tuple, (n isa Splat ? Expr(:..., _output_var(splatname(n))) : _output_var(n) for n in names)...)
        :($lhs = $call)
    else   # :properties
        quote
            value = $call
            $((:($(_output_var(last(p))) = getproperty(value, $(QuoteNode(first(p))))) for p in names)...)
        end
    end
    checks = [:($(_output_var(plan_names[i]))::$(fieldtype(types, i))) for i in 1:length(plan_names) if fieldtype(types, i) !== Any]
    # Built by a function call, not a literal: for a value of type `Union{Nothing, T}` a literal infers as the abstract
    # `NamedTuple{names, <:Tuple}`, which the generated merge cannot handle; a call is split into one concrete type per case.
    result = :(@inline _call_result(Val($(Tuple(plan_names))), $(map(_output_var, plan_names)...)))
    return quote
        $(reads...)
        $assign
        $(checks...)
        return $result
    end
end

@inline _call_result(::Val{names}, values::Vararg{Any, N}) where {names, N} = NamedTuple{names}(values)

@inline init(::Callable, context) = (;)
@inline cleanup(::Callable, context) = (;)

"""
The return names of a `Callable` (the field names of `R`) that its view (`SCV`) sees: a state field or local it is
wired to, or its slot in the scope (a captured return that something in the scope reads, see `_resolve_scopes`).
The others are read by nothing and dropped.
"""
function _call_return_names(@nospecialize(SCV::Type), @nospecialize(R::Type))
    names = Symbol[]
    for name in fieldnames(R)
        isnothing(first(_compute_location(SCV, name))) || push!(names, name)
    end
    return Tuple(names)
end

"""The returned values `retval` keeps for the view, as a named tuple expression."""
_kept_returns_expr(names) = Expr(:tuple, Expr(:parameters, (Expr(:kw, name, :(getproperty(retval, $(QuoteNode(name))))) for name in names)...))

@inline @generated function _call_payload(contextview::SCV, retval::R) where {SCV<:SubContextView, R<:NamedTuple}
    names = _call_return_names(SCV, R)
    isempty(names) && return :((;))
    return :(@inline _build_merge_payload(contextview, $(_kept_returns_expr(names)), ReturnDemand{$names}()))
end

"""Merge a `Callable` return through its view: each name the view sees is written where it lives (see `_call_return_names`)."""
@inline @generated function merge_call_return(contextview::SCV, retval::R) where {SCV<:SubContextView, R<:NamedTuple}
    names = _call_return_names(SCV, R)
    isempty(names) && return :(@inline getbundle(contextview))
    return :(@inline merge(contextview, $(_kept_returns_expr(names))))
end

"""Step a `Callable` child: view the context from the shared `_captured_returns` namespace, call, merge the returns."""
@inline function _step!(ex::EX, lc::L, wiring::W, namespace::Namespace, session::P, lifetime::LT) where {EX<:Callable, L<:LoopContext, W<:PlanWiringView, P<:ProcessSession, LT<:Lifetime}
    contextview = @inline _leaf_view(ex, lc, wiring, Namespace{:_captured_returns}())
    retval = @inline step!(ex, contextview)
    return @inline merge_call_return(contextview, retval)
end

# The persistent fields a `Callable` writes (see src/Context/Carried/Writes.jl): its view-visible returns.
@inline function _leaf_payload(ex::EX, lc::L, wiring::W, namespace::N) where {EX<:Callable,L,W,N}
    contextview = @inline _leaf_view(ex, lc, wiring, Namespace{:_captured_returns}())
    return @inline _call_payload(contextview, (@inline step!(ex, contextview)))
end
