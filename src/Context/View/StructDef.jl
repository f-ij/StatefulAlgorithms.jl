
"""
A location of a variable in subcontext: subcontextname and which has the local name there: originalname
the type parameter indicates whether its a local, shared or routed variable
TODO: is type really neccesary anywhere?
"""
struct VarLocation{Type, subcontextname, originalname, func, reversefunc} end
VarLocation{Type}(subcontextname::Symbol, originalname::Union{Tuple, Symbol}, func = nothing, reversefunc = nothing) where {Type} = VarLocation{Type, subcontextname, originalname, func, reversefunc}()
VarLocation(type, subcontextname::Symbol, originalname::Union{Tuple, Symbol}, func = nothing, reversefunc = nothing) = VarLocation{type, subcontextname, originalname, func, reversefunc}()

@inline getfunc(vl::Union{VarLocation{T, subcontextname, originalname, func}, Type{<:VarLocation{T, subcontextname, originalname, func}}}) where {T, subcontextname, originalname, func} = func

"""Return the writeback transform carried by a `VarLocation`."""
@inline getreversefunc(vl::Union{VarLocation{T, subcontextname, originalname, func, reversefunc}, Type{<:VarLocation{T, subcontextname, originalname, func, reversefunc}}}) where {T, subcontextname, originalname, func, reversefunc} = reversefunc
@inline get_subcontextname(vl::Union{VarLocation{T, SCN, ON}, Type{<:VarLocation{T, SCN, ON}}}) where {T, SCN, ON} = SCN
@inline get_originalname(vl::Union{VarLocation{T, SCN, ON}, Type{<:VarLocation{T, SCN, ON}}}) where {T, SCN, ON} = ON

"""
For variable names :a, :b, :c
    create the expression :(func(:a, :b, :c)) where func is the function to apply to the variable names
"""
@inline function funcexpr(vl::Union{VL, Type{<:VL}}, 
        varnames...) where VL <: VarLocation
            func = getfunc(vl) 
            if isnothing(func)
                if length(varnames) == 1 # If no func, can only have one var
                    return :($(varnames[1]))
                else 
                    error("Error: VarLocation: $vl with a function must have exactly one variable name, got $(varnames)")
                end
            end
            return Expr(:call, func, varnames...)
end

@inline function getvar_expressions_and_varnames(vl::Union{VL, Type{<:VL}}) where VL <: VarLocation
    varnames = get_originalname(vl)
    numvars = varnames isa Tuple ? length(varnames) : 1
    varnames = varnames isa Tuple ? varnames : (varnames,)
    assign_symbols = ntuple(i -> gensym(:var), numvars)
    target_subcontext = get_subcontextname(vl)
    return [:($(assign_symbols[i]) = @inline getproperty_fromsubcontext(sct, Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(varnames[i])))))
        for i in 1:numvars], assign_symbols
end

struct SubContextView{CType, SubName, RuntimeCType, T, NT, VarAliases, SharedContexts, SharedVars} <: AbstractContext
    context::CType
    runtimecontext::RuntimeCType
    instance::T # ScopedInstance for which the view is created
    injected::NT

    function SubContextView{CType, SubName, RuntimeCType, T, NT}(context::CType, runtimecontext::RuntimeCType, instance::T; inject::NT = (;)) where {CType, SubName, RuntimeCType, T, NT}
        new{CType, SubName, RuntimeCType, T, typeof(inject), varaliases(instance), (), ()}(context, runtimecontext, instance, inject)
    end

    function SubContextView{CType, SubName, RuntimeCType, T, NT, VarAliases, SharedContexts, SharedVars}(context::CType, runtimecontext::RuntimeCType, instance::T, inject::NT = (;)) where {CType, SubName, RuntimeCType, T, NT, VarAliases, SharedContexts, SharedVars}
        new{CType, SubName, RuntimeCType, T, typeof(inject), VarAliases, SharedContexts, SharedVars}(context, runtimecontext, instance, inject)
    end
end
