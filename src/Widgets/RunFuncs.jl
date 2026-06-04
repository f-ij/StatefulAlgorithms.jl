export RunFuncs
struct RunFuncs{Varnames, Fs} <: ProcessAlgorithm
    fs::Fs
end
function RunFuncs(args...)
    # First find all funcs
    first_symb = findfirst(arg -> arg isa Symbol, args)
    funcs = args[1:first_symb-1]
    varnames = args[first_symb:end]
    @assert all(funcs) do f
        f isa Function
    end "All arguments before the first Symbol must be functions"
    @assert all(varnames) do v
        v isa Symbol
    end "All arguments after the first function must be symbols"
    return RunFuncs{tuple(varnames...), typeof(funcs)}(tuple(funcs...))
end

@generated function unroll_apply(funcs::F, vars::T) where {F, T <: Tuple}
    func_exprs = [:(funcs[$i](vars...)) for i in 1:length(F.parameters)]
    return Expr(:tuple, func_exprs...)
end


Base.@constprop :aggressive @inline function apply_runfuncs(rf::RunFuncs{Varnames, Fs}, vars...) where {Varnames, Fs}
    return @inline unroll_apply(rf.fs::Fs, vars)
end


@generated function step!(rf::RunFuncs{Varnames, Fs}, context) where {Varnames, Fs}
    get_context_splat = namedtuple_destructure_expr(:context, Varnames...)
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        $get_context_splat
        result = apply_runfuncs(rf, $(Varnames...))
        return (;result)
    end
end