export FuncWrapper

struct ValueRef{index} end
to_expr(::ValueRef{index}, varname) = :(getindex(getproperty($varname, :values), $index))


"""
Wrap a plain function so it behaves like a `ProcessAlgorithm`.

`InputSymbols` are routed positionally, `OutputSymbols` are written back by name,
and `Kwargs` can point either to context symbols or inline literal values.
"""
struct FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs, T} <: ProcessAlgorithm
    func::F
    values::T
end

inputsymbols_to_exprs(inputs, varname) = (inputs[i] isa Symbol ? :($(inputs[i])) : to_expr(inputs[i], varname) for i in 1:length(inputs))

@generated function step!(fw::FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs, T}, context::C) where {F, InputSymbols, OutputSymbols, Kwargs, T, C}
    kwargnames = keys(Kwargs)
    kwargvals = values(Kwargs)
    kwargvalnames = filter(x -> x isa Symbol, kwargvals)
    kwexprs = (Expr(:kw, kwargnames[i], kwargvals[i]) for i in 1:length(kwargnames))
    call_expr = :(fw.func($(inputsymbols_to_exprs(InputSymbols, :fw)...); $(kwexprs...)))
    output_assignment = isempty(OutputSymbols) ? call_expr : :($(OutputSymbols...) = $call_expr)
    return_expr = isempty(OutputSymbols) ? :(return (;)) : :(return (;$(OutputSymbols...)))
    return quote
        (;$(InputSymbols...), $(kwargvalnames...)) = context
        $output_assignment
        $return_expr
    end
    # error( quote
    #     (;$(InputSymbols...), $(kwargvalnames...)) = context
    #     $(OutputSymbols...) = fw.func($(InputSymbols...); $(kwexprs...))
    #     return (;$(OutputSymbols...))
    # end)
end

@generated function init(fw::FuncWrapper{F, InputSymbols, OutputSymbols, Kwargs}, context::C) where {F, InputSymbols, OutputSymbols, Kwargs, C}
    kwargnames = keys(Kwargs)
    kwargvals = values(Kwargs)
    kwargvalnames = filter(x -> x isa Symbol, kwargvals)
    kwexprs = (Expr(:kw, kwargnames[i], kwargvals[i]) for i in 1:length(kwargnames))
    call_expr = :(fw.func($(inputsymbols_to_exprs(InputSymbols, :fw)...); $(kwexprs...)))
    output_assignment = isempty(OutputSymbols) ? call_expr : :($(OutputSymbols...) = $call_expr)
    return_expr = isempty(OutputSymbols) ? :(return (;)) : :(return (;$(OutputSymbols...)))
    return quote
        try
            # During init the routed inputs may not exist yet. In that case we just
            # skip seeding this wrapper and let step! populate it later.
            (;$(InputSymbols...), $(kwargvalnames...)) = context
            $output_assignment
            $return_expr
        catch
            return (;)
        end
    end
end

function FuncWrapper(f::F, inputs, outputsyms::NTuple{M, Symbol}) where {F, M}
    newinputs = ntuple(x -> inputs[x] isa Symbol ? inputs[x] : ValueRef{x}(), length(inputs))
    values = filter(x -> !(x isa Symbol), inputs)
    values = map(x -> x isa QuoteNode ? x.value : x, values)
    FuncWrapper{F, newinputs, outputsyms, NamedTuple(), typeof(values)}(f, values)
end

function FuncWrapper(f::F, inputs::Tuple, outputsyms::NTuple{M, Symbol}, kwargs::NamedTuple) where {F, M}
    newinputs = ntuple(x -> inputs[x] isa Symbol ? inputs[x] : ValueRef{x}(), length(inputs))
    values = filter(x -> !(x isa Symbol), inputs)
    values = map(x -> x isa QuoteNode ? x.value : x, values)
    FuncWrapper{F, newinputs, outputsyms, kwargs, typeof(values)}(f, values)
end

function FuncWrapper(f::F, inputs, outputsyms::NTuple{M, Symbol}, kwargs::NTuple{K, Symbol}) where {F, N, M, K}
    newinputs = ntuple(x -> inputs[x] isa Symbol ? inputs[x] : ValueRef{x}(), length(inputs))
    values = filter(x -> !(x isa Symbol), inputs)
    same_name_kwargs = NamedTuple{kwargs}(kwargs)
    values = map(x -> x isa QuoteNode ? x.value : x, values)
    FuncWrapper{F, newinputs, outputsyms, same_name_kwargs, typeof(values)}(f, values)
end
