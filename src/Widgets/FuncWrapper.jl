export FuncWrapper

struct ValueRef{index, T} end

to_expr(::ValueRef{index, T}, varname) where {index, T} = :((getindex(getproperty($varname, :values), $index))::$T)
@inline _valueref_index(::ValueRef{index, T}) where {index, T} = index

"""
The DSL's description of a plain function call, used while a plan is built: the function,
which context names become its positional and keyword arguments (`InputSymbols`, `Kwargs`,
literal values in `values`), and which names its return is written to (`OutputSymbols`).
`display` keeps the source form for printing.

The plan constructor turns it into an [`Executable`](@ref). It is mutable only so that routes
the DSL attaches to one call (`LocalPlanOption`) can be matched to that call by identity first.
"""
mutable struct FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs, T} <: ProcessAlgorithm
    const func::F
    const values::T
    const display::Any
end

"""
Endpoint of a route that belongs to one plan child (a `WithWiring` wire, or a route the DSL
attached to a call): matched to its child when the plan is built, and pointed at that child's
namespace at resolve.
"""
struct OwnerMatcher <: AbstractMatcher{nothing} end
@inline match_by(::FuncWrapper) = OwnerMatcher()
@inline match_by(::Type{<:FuncWrapper}) = OwnerMatcher
match(child::FuncWrapper, owner::FuncWrapper) = child === owner
match(child, owner::FuncWrapper) = false
match(child::FuncWrapper, owner) = false

"""
    _funcwrapper_return_names(SCV, R, DemandNames)

Split the return names of a `FuncWrapper` (the field names of `R`): names visible in its view (`SCV`) are real
state/writeback targets; the others are temporary runtime outputs for later DSL statements, kept when demanded.
"""
function _funcwrapper_return_names(SCV::Type, R::Type, DemandNames)
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

# The persistent fields a FuncWrapper writes (see src/Context/Carried/Writes.jl): its view-visible returns.
@inline function _leaf_payload(fw::FW, context::C, runtimecontext::RC, wiring::W, namespace::N) where {FW<:FuncWrapper,C,RC,W,N}
    contextview = @inline _leaf_view(fw, context, runtimecontext, wiring, namespace)
    return @inline _funcwrapper_payload(contextview, (@inline step!(fw, contextview)))
end

@inline _funcwrapper_payload(contextview::SCV, ::Nothing) where {SCV<:SubContextView} = (;)
@inline @generated function _funcwrapper_payload(contextview::SCV, retval::R) where {SCV<:SubContextView, R<:NamedTuple}
    view_names, _ = _funcwrapper_return_names(SCV, R, ())
    isempty(view_names) && return :((;))
    view_expr = Expr(:tuple, Expr(:parameters, (Expr(:kw, name, :(getproperty(retval, $(QuoteNode(name))))) for name in view_names)...))
    return :(@inline _merge_payload(contextview, $view_expr, ReturnDemand{$(Tuple(view_names))}()))
end

"""
Merge a `FuncWrapper` return into the correct runtime target.

Outputs whose names already resolve in the wrapper view are routed/shared/local
writebacks and should be merged through `SubContextView`. New output names are
DSL temporaries and remain in `ProcessContext._runtime` for later statements.
"""
@inline @generated function merge_funcwrapper_return(
    contextview::SCV,
    context::C,
    runtimecontext::RC,
    retval::R,
    ) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext, R<:NamedTuple}
    demand_type = ReturnDemand{fieldnames(R)}
    return :(merge_funcwrapper_return(contextview, context, runtimecontext, retval, $demand_type()))
end

@inline @generated function merge_funcwrapper_return(
    contextview::SCV,
    context::C,
    runtimecontext::RC,
    retval::R,
    demand::ReturnDemand{DemandNames},
) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext, R<:NamedTuple, DemandNames}
    view_names, runtime_names = _funcwrapper_return_names(SCV, R, DemandNames)

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
Treat a `FuncWrapper` with no return value as a pure side-effecting step.
"""
@inline merge_funcwrapper_return(contextview::SCV, context::C, runtimecontext::RC, ::Nothing) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext} = context, runtimecontext
@inline merge_funcwrapper_return(contextview::SCV, context::C, runtimecontext::RC, ::Nothing, demand::ReturnDemand) where {SCV<:SubContextView, C<:ProcessContext, RC<:ProcessContext} = context, runtimecontext

@inline _funcwrapper_render_value(value; io::IO = stdout) = sprint(show, value; context = io)

@inline function _funcwrapper_render_display(value; io::IO = stdout)
    if value isa Symbol
        return string(value)
    elseif value isa QuoteNode
        return _funcwrapper_render_value(value.value; io)
    elseif value isa Expr
        rendered = sprint(show, value)
        if startswith(rendered, ":(") && endswith(rendered, ")")
            first_idx = nextind(rendered, 2)
            last_idx = prevind(rendered, lastindex(rendered))
            return first_idx > last_idx ? "" : String(SubString(rendered, first_idx, last_idx))
        end
        return rendered
    else
        return _funcwrapper_render_value(value; io)
    end
end

@inline function _funcwrapper_render_input(input, values; io::IO = stdout)
    if input isa Symbol
        return string(input)
    else
        return _funcwrapper_render_value(values[_valueref_index(input)]; io)
    end
end

@inline function _funcwrapper_signature_parts(
    ::Type{<:FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs}},
    display;
    io::IO = stdout,
) where {F, InputSymbols, OutputSymbols, Kwargs}
    positional = [_funcwrapper_render_display(input; io) for input in display.positional]
    kwargs_rendered = [string(name, " = ", _funcwrapper_render_display(value; io)) for (name, value) in pairs(display.kwargs)]
    outputs = isempty(OutputSymbols) ? "nothing" : "(; " * join(string.(OutputSymbols), ", ") * ")"
    return positional, kwargs_rendered, outputs
end

@inline function _funcwrapper_signature_string(fw::FuncWrapper; io::IO = stdout)
    positional, kwargs_rendered, outputs = _funcwrapper_signature_parts(typeof(fw), getfield(fw, :display); io)
    args = if isempty(kwargs_rendered)
        join(positional, ", ")
    elseif isempty(positional)
        "; " * join(kwargs_rendered, ", ")
    else
        join(positional, ", ") * "; " * join(kwargs_rendered, ", ")
    end
    return "(" * args * ") -> " * outputs
end

@inline _funcwrapper_callable_label(f) = sprint(show, f)

@inline _funcwrapper_display_bundle(inputs::Tuple, kwargs::NamedTuple) = (; positional = inputs, kwargs)
@inline _funcwrapper_default_display_inputs(inputs) = tuple(inputs...)

function _funcwrapper_encode_inputs(inputs)
    literal_values = Any[]
    literal_idx = 0
    encoded = ntuple(length(inputs)) do i
        input = inputs[i]
        if input isa Symbol
            input
        else
            value = input isa QuoteNode ? input.value : input
            literal_idx += 1
            push!(literal_values, value)
            ValueRef{literal_idx, typeof(value)}()
        end
    end
    return encoded, tuple(literal_values...)
end

inputsymbols_to_exprs(inputs, varname) = (inputs[i] isa Symbol ? :($(inputs[i])) : to_expr(inputs[i], varname) for i in 1:length(inputs))
context_input_symbols(inputs) = tuple((x for x in inputs if x isa Symbol)...)

@inline @generated function step!(fw::FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs, T}, context::C) where {F, InputSymbols, OutputSymbols, Kwargs, T, C}
    positional_names = context_input_symbols(InputSymbols)
    kwargnames = keys(Kwargs)
    kwargvals = values(Kwargs)
    kwargvalnames = tuple((x for x in kwargvals if x isa Symbol)...)
    kwexprs = (Expr(:kw, kwargnames[i], kwargvals[i]) for i in 1:length(kwargnames))
    call_expr = :(@inline fw.func($(inputsymbols_to_exprs(InputSymbols, :fw)...); $(kwexprs...)))
    output_assignment = isempty(OutputSymbols) ? call_expr : :($(OutputSymbols...) = $call_expr)
    return_expr = isempty(OutputSymbols) ? :(return (;)) : :(return (;$(OutputSymbols...)))
    quote
        (;$(positional_names...), $(kwargvalnames...)) = context
        $output_assignment
        $return_expr
    end
end

@inline init(::FuncWrapper, context::AbstractContext) = context
@inline init(::FuncWrapper, context) = (;)
@inline cleanup(::FuncWrapper, context::AbstractContext) = context
@inline cleanup(::FuncWrapper, context) = (;)

function _funcwrapper_construct(f::F, inputs, outputsyms::NTuple{M, Symbol}, kwargs::NamedTuple, display_inputs::Tuple, display_kwargs::NamedTuple) where {F, M}
    newinputs, values = _funcwrapper_encode_inputs(inputs)
    display = _funcwrapper_display_bundle(display_inputs, display_kwargs)
    FuncWrapper{F, newinputs, outputsyms, kwargs, typeof(values)}(f, values, display)
end

function FuncWrapper(f::F, inputs, outputsyms::NTuple{M, Symbol}) where {F, M}
    _funcwrapper_construct(f, inputs, outputsyms, NamedTuple(), _funcwrapper_default_display_inputs(inputs), NamedTuple())
end

function FuncWrapper(f::F, inputs::Tuple, outputsyms::NTuple{M, Symbol}, kwargs::NamedTuple) where {F, M}
    _funcwrapper_construct(f, inputs, outputsyms, kwargs, _funcwrapper_default_display_inputs(inputs), kwargs)
end

function FuncWrapper(f::F, inputs::Tuple, outputsyms::NTuple{M, Symbol}, kwargs::NamedTuple, display_inputs::Tuple, display_kwargs::NamedTuple) where {F, M}
    _funcwrapper_construct(f, inputs, outputsyms, kwargs, display_inputs, display_kwargs)
end

function FuncWrapper(f::F, inputs, outputsyms::NTuple{M, Symbol}, kwargs::NTuple{K, Symbol}) where {F, M, K}
    same_name_kwargs = NamedTuple{kwargs}(kwargs)
    _funcwrapper_construct(f, inputs, outputsyms, same_name_kwargs, _funcwrapper_default_display_inputs(inputs), same_name_kwargs)
end

function Base.summary(io::IO, fw::FuncWrapper)
    print(io, "FuncWrapper(", _funcwrapper_signature_string(fw; io), ")")
end

function Base.show(io::IO, fw::FuncWrapper)
    print(
        io,
        "FuncWrapper(",
        _funcwrapper_signature_string(fw; io),
        ", ",
        _funcwrapper_callable_label(getfield(fw, :func)),
        ")",
    )
end

function Base.show(io::IO, ::MIME"text/plain", fw::FuncWrapper)
    println(io, "FuncWrapper")
    println(io, "├── signature = ", _funcwrapper_signature_string(fw; io))
    print(io, "└── function = ", _funcwrapper_callable_label(getfield(fw, :func)))
    return nothing
end
