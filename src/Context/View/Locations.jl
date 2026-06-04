##########################################
########## Variable Locations ############
##########################################

# This is the basis for the viewsystem. Variables in and out get mapped to locations in the full context

"""
 Local variables => VarLocations
"""

function get_local_locations(sct::Type{SCT}) where {SCT<:SubContextView{CType, SubKey}} where {CType, SubKey}
    _subcontext_type = subcontext_type(SCT)
    local_varnames = keys(_subcontext_type)

    localst = ntuple(i ->VarLocation{:local}(SubKey, local_varnames[i]), length(local_varnames))
    return NamedTuple{(local_varnames...,)}(localst)
end

"""
Shared subcontexts => VarLocations
"""
@inline _view_shared_types(shared) = shared isa Tuple ? shared : (shared,)

function get_shared_locations(sct::Type{SCT}) where {SCT<:SubContextView{CType, SubKey}} where {CType, SubKey}
    shared_context_names = contextname.(_view_shared_types(view_sharedcontexts(SCT)))

    sharedvars = named_flat_collect_broadcast(shared_context_names) do name
        shared_subcontext_type = subcontext_type(CType, name)
        shared_varnames = keys(shared_subcontext_type)
        pairs = (shared_varnames[i] => VarLocation{:subcontext}(name, shared_varnames[i]) for i in 1:length(shared_varnames))
        return NamedTuple(pairs)
    end
    return sharedvars
end

"""
Routes supplied to the view => VarLocations.
"""
function get_routed_locations(sct::Type{SCT}) where {SCT<:SubContextView{CType, SubKey}} where {CType, SubKey}
    sharedvars = _view_shared_types(view_sharedvars(SCT))

    routedvars = named_flat_collect_broadcast(sharedvars) do sv
        fromname = get_fromname(sv)
        _localnames = localnames(sv)
        _subvarcontextnames = subvarcontextnames(sv)
        _transform = gettransform(sv)
        _reverse_transform = getreverse_transform(sv)
        location_type = (fromname == :_runtime || fromname == :_input) ? :runtime : :subcontext
        pairs = (_localnames[i] => VarLocation{location_type}(fromname, _subvarcontextnames[i], _transform, _reverse_transform) for i in 1:length(_localnames))
        return NamedTuple(pairs)
    end

    return routedvars
end

function get_injected_locations(sct::Type{SCT}) where {SCT<:SubContextView{CType, SubKey}} where {CType, SubKey}
    injected_vars = injectedfieldnames(SCT)
    injst = ntuple(i ->VarLocation{:injected}(SubKey, injected_vars[i]), length(injected_vars))
    return NamedTuple{(injected_vars...,)}(injst)
end


"""
Generate a namedtuple of localtuple => VarLocation
"""
function _compute_varlocations(::Type{C}) where {C<:SubContextView{CType, SubKey}} where {CType, SubKey}
    locals = get_local_locations(C)
    sharedvars = get_shared_locations(C)
    routedvars = get_routed_locations(C)
    injectedvars = get_injected_locations(C)
    # Locals take precedene over routes which take precedence over shared if there are name clashes
    # Injected take precedence over all
    return (;sharedvars..., routedvars..., locals..., injectedvars...)
end

"""
Get a flat named tuple with (;name_of_runtime_var => VarLocation)
A varlocation is an actual location of the variable in the full context
"""
function _compute_all_locations(::Type{SCT}) where {SCT<:SubContextView}
    locals = get_local_locations(SCT)
    sharedvars = get_shared_locations(SCT)
    routedvars = get_routed_locations(SCT)
    injectedvars = get_injected_locations(SCT)
    # Locals take precedene over routes which take precedence over shared
    return (;sharedvars..., routedvars..., locals..., injectedvars...)
end

@inline @generated function _generated_varlocations(::Type{C}) where {C<:SubContextView}
    locations = _compute_varlocations(C)
    return :( $locations )
end

@inline @generated function _generated_all_locations(::Type{SCT}) where {SCT<:SubContextView}
    locations = _compute_all_locations(SCT)
    return :( $locations )
end

get_varlocations(scv::SubContextView) = @inline get_varlocations(typeof(scv))
@inline get_varlocations(scv::Type{C}) where {C<:SubContextView} = _generated_varlocations(C)

@inline get_all_locations(scv::SubContextView) = @inline get_all_locations(typeof(scv))
@inline get_all_locations(sctv::Type{SCT}) where {SCT<:SubContextView} = _generated_all_locations(SCT)

function _compute_location(::Type{SCT}, name::Symbol) where {SCT<:SubContextView}
    subcontext_name = algo_to_subcontext_names(SCT, name)

    injected = get_injected_locations(SCT)
    hasproperty(injected, subcontext_name) && return getproperty(injected, subcontext_name), subcontext_name

    local_locations = get_local_locations(SCT)
    hasproperty(local_locations, subcontext_name) && return getproperty(local_locations, subcontext_name), subcontext_name

    routed = get_routed_locations(SCT)
    hasproperty(routed, subcontext_name) && return getproperty(routed, subcontext_name), subcontext_name

    shared = get_shared_locations(SCT)
    hasproperty(shared, subcontext_name) && return getproperty(shared, subcontext_name), subcontext_name

    return nothing, subcontext_name
end

###########################################
########### Getting Properties  ###########
###########################################

@inline Base.keys(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.propertynames(scv::SCV) where SCV <: SubContextView = @inline propertynames(@inline get_all_locations(scv))
@inline Base.haskey(scv::SCV, name::Symbol) where SCV <: SubContextView = @inline haskey(get_all_locations(scv), name)
@inline getregistry(scv::SCV) where SCV <: SubContextView = getregistry(getcontext(scv))

@inline function _runtime_subcontext_data(runtimecontext::ProcessContext, ::Val{subcontextname}) where {subcontextname}
    subcontexts = @inline get_subcontexts(runtimecontext)
    return haskey(subcontexts, subcontextname) ? getdata(getproperty(subcontexts, subcontextname)) : (;)
end

@inline function _runtime_has_var(runtimecontext::ProcessContext, ::Val{subcontextname}, ::Val{varname}) where {subcontextname,varname}
    return haskey(_runtime_subcontext_data(runtimecontext, Val(subcontextname)), varname)
end

@inline function _runtime_get_var(runtimecontext::ProcessContext, ::Val{subcontextname}, ::Val{varname}) where {subcontextname,varname}
    return getproperty(_runtime_subcontext_data(runtimecontext, Val(subcontextname)), varname)
end

"""
    subcontext_view_value(value)

Return the value exposed by `SubContextView` reads for one stored field.
Wrapper storage types can overload this to present algorithm-facing values
without changing the persistent context representation.
"""
@inline subcontext_view_value(value) = value

"""
    subcontext_writeback_value(old, returned)

Return the value that should be written to context when an algorithm returns
`returned` for a field currently storing `old`.
"""
@inline subcontext_writeback_value(::Any, returned) = returned

@inline function getproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    runtimecontext = @inline getruntimecontext(scv)
    if subcontextname === :_input || subcontextname === :_runtime
        return @inline subcontext_view_value(_runtime_get_var(runtimecontext, Val(subcontextname), Val(varname)))
    end
    context = @inline getcontext(scv)
    subcontexts = @inline get_subcontexts(context)
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        if @inline haskey(getdata(subcontext), varname)
            return @inline subcontext_view_value(getproperty(subcontext, varname))
        end
    end
    if @inline _runtime_has_var(runtimecontext, Val(subcontextname), Val(varname))
        return @inline subcontext_view_value(_runtime_get_var(runtimecontext, Val(subcontextname), Val(varname)))
    end
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        return @inline subcontext_view_value(getproperty(subcontext, varname))
    end
    error("Subcontext `$subcontextname` is not available in state or runtime context.")
end

"""
    storedproperty_fromsubcontext(scv, Val(subcontext), Val(varname))

Return the backing value stored for one `SubContextView` location without
applying `subcontext_view_value`. Writeback hooks use this to inspect wrappers
that are hidden from algorithm code during normal reads.
"""
@inline function storedproperty_fromsubcontext(
    scv::SCV,
    ::Val{subcontextname},
    ::Val{varname},
) where {SCV<:SubContextView, subcontextname, varname}
    context = @inline getcontext(scv)
    subcontexts = @inline get_subcontexts(context)
    if haskey(subcontexts, subcontextname)
        subcontext = @inline getproperty(subcontexts, subcontextname)
        if @inline haskey(getdata(subcontext), varname)
            return @inline getproperty(subcontext, varname)
        end
    end
    if @inline _runtime_has_var(getruntimecontext(scv), Val(subcontextname), Val(varname))
        return @inline _runtime_get_var(getruntimecontext(scv), Val(subcontextname), Val(varname))
    end
    error("Variable `$subcontextname.$varname` is not available in state or runtime context.")
end
@inline getinjected(scv::SCV, key) where SCV <: SubContextView = getproperty(getinjected(scv), key)
@inline function Base.get(scv::SCV, name::Symbol, default) where SCV <: SubContextView
    if haskey(scv, name)
        return getproperty(scv, Val(name))
    else
        return default
    end
end

@inline Base.@constprop :aggressive Base.getproperty(sct::SubContextView, v::Symbol) = getproperty(sct, Val(v))
@inline Base.@constprop :aggressive Base.getindex(sct::SubContextView, v::Symbol) = getproperty(sct, Val(v))

# """
# Equivalent to getproperty(sct, Val(name)), but allows for inlining and constant propagation on the name argument
# """
# function Base.getproperty(sct::SubContextView, symb::S) where S <: Symbol
#     locations = get_all_locations(sct)
#     subcontext_name = algo_to_subcontext_names(sct, symb)
#     varlocation = @inline getproperty(locations, subcontext_name)
#     return @inline getproperty(sct, varlocation)
# end

@inline @generated function Base.getproperty(sct::SCV, vl::Union{VarLocation{:subcontext}, VarLocation{:local}}) where SCV <: SubContextView
    target_subcontext = get_subcontextname(vl)
    target_variable = get_originalname(vl)
    if isnothing(getfunc(vl)) && target_variable isa Symbol
        return quote
            return @inline getproperty_fromsubcontext(sct, Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(target_variable))))
        end
    end

    assign_exprs, varsymbols = getvar_expressions_and_varnames(vl)
    fexpr = funcexpr(vl, varsymbols...)
    
    return  quote
        $(assign_exprs...)
        return $(fexpr)
    end
end

"""
Read a routed runtime variable from the runtime context.
"""
@inline @generated function Base.getproperty(sct::SCV, vl::VarLocation{:runtime}) where SCV <: SubContextView
    target_subcontext = get_subcontextname(vl)
    target_variables = get_originalname(vl)
    if isnothing(getfunc(vl)) && target_variables isa Symbol
        return quote
            return @inline subcontext_view_value(_runtime_get_var(getruntimecontext(sct), Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(target_variables)))))
        end
    end

    varnames = target_variables isa Tuple ? target_variables : (target_variables,)
    varsymbols = ntuple(i -> gensym(:runtime_var), length(varnames))
    assign_exprs = [
        :($(varsymbols[i]) = @inline subcontext_view_value(_runtime_get_var(getruntimecontext(sct), Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(varnames[i]))))))
        for i in eachindex(varnames)
    ]
    fexpr = funcexpr(vl, varsymbols...)

    return quote
        $(assign_exprs...)
        return $(fexpr)
    end
end

@inline @generated function Base.getproperty(sct::SCV, vl::VarLocation{:injected}) where SCV <: SubContextView
    target_variable = get_originalname(vl)
    return quote
        injected = getinjected(sct)
        return @inline getproperty(injected, $(QuoteNode(target_variable)))
    end
end

@inline @generated function Base.haskey(scv::SCV, v::Val{name}) where {name} where SCV <: SubContextView
    location, subcontext_name = _compute_location(SCV, name)
    has_key = !isnothing(location)
    return :( $has_key )
end

@inline @generated function Base.getproperty(sct::SubContextView{CType, SubKey}, v::Val{key}) where {CType, SubKey, key}    

    target_location, subcontextname = _compute_location(sct, key)
    if !isnothing(target_location)
        return quote 
            $(LineNumberNode(@__LINE__, @__FILE__))
            @inline getproperty(sct, $target_location) 
        end
        else
            locations = get_all_locations(sct)
            available = keys(locations)
            return quote
                if @inline _runtime_has_var(getruntimecontext(sct), Val($(QuoteNode(SubKey))), Val($(QuoteNode(key))))
                    return @inline _runtime_get_var(getruntimecontext(sct), Val($(QuoteNode(SubKey))), Val($(QuoteNode(key))))
                end
                if $(QuoteNode(subcontextname)) == $(QuoteNode(key))
                    $(LineNumberNode(@__LINE__, @__FILE__))
                    a_name = $(QuoteNode(key))
                context = getcontext(sct)
                available_names = $available
                sct_name = $(QuoteNode(subcontextname))
                msg = "Variable $(a_name) requested from $(sct) in View: $(SubKey), but not supplied to context. Available names are: $(available_names) \n Context: $(context)"
            else
                msg = "Variable $(a_name) (mapped to $(sct_name)) requested from $(sct) in View: $(SubKey), but not supplied to context. Available names are: $(available_names) \n Context: $(context)"
            end
            error(msg)
        end
    end
end


@inline @generated function Base.iterate(scv::SCV, state = 1) where SCV <: SubContextView
    locations = get_all_locations(scv)
    _keys = keys(locations)
    return quote 
        if state > length($_keys)
            return nothing
        else
            return (($_keys[state], getproperty(scv, getproperty($locations, $_keys[state]))), state + 1)
        end
    end
end


##########################################
"""
From a pair of a namedtuple intended to merge into context from a view
And all locations in the view
    Create a namedtuple (;target_subcontext => (;var1 = value1, var2 = value2,...),...)
"""
function create_merge_tuples_expr(locations::Locs, args) where Locs
    argsnames_to_merge = fieldnames(args)
    subcontext_merge_parameter_exprs = (;)
    for localname in argsnames_to_merge
        varlocation = getproperty(locations, localname)
        target_subcontext = get_subcontextname(varlocation)
        target_variable = get_originalname(varlocation)

        subcontext_nt_parameters = get(subcontext_merge_parameter_exprs, target_subcontext, Expr(:parameters))
        subcontext_merge_parameter_exprs = (;subcontext_merge_parameter_exprs..., target_subcontext => subcontext_nt_parameters)

        kw_expr = Expr(:kw, target_variable, :(getproperty(args, $(QuoteNode(localname)))))
        push!(subcontext_nt_parameters.args, kw_expr)
    end

    total_nt_expr = Expr(:tuple, Expr(:parameters,
            ((Expr(:kw, subctx, Expr(:tuple,Expr(:parameters, parameter_exprs...))) for (subctx, parameter_exprs) in subcontext_merge_parameter_exprs)...
        )
        )
    )
    return total_nt_expr
end
