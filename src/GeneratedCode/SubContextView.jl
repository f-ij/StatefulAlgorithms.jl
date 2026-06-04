
@inline function Base.merge(scv::SubContextView{CType, SubKey}, ::Nothing) where {CType<:ProcessContext, SubKey}
    return (@inline getcontext(scv)), (@inline getruntimecontext(scv))
end

function _subcontext_view_mergetuple_expr(SCV::Type, Args::Type)
    @nospecialize SCV Args
    merge_expr, runtime_expr = _subcontext_view_merge_exprs(SCV, Args)
    return merge_expr
end

function _subcontext_view_merge_exprs(SCV::Type, Args::Type, demanded_runtime_names = fieldnames(Args))
    @nospecialize SCV Args
    SubKey = SCV.parameters[2]
    algo_varnames = fieldnames(Args)
    demand_all = demanded_runtime_names === :all

    merge_preambles_by_subcontext = Dict{Symbol, Vector{Expr}}()
    merge_expressions_by_subcontext = Dict{Symbol, Vector{Expr}}()
    runtime_expressions_by_subcontext = Dict{Symbol, Vector{Expr}}()

    for (var_idx, algo_varname) in enumerate(algo_varnames)
        target_location, subcontext_varname = _compute_location(SCV, algo_varname)
        # First look if varname is in locations
        if !isnothing(target_location) # If the local variable exists
            target_subcontext = get_subcontextname(target_location)
            targetname = get_originalname(target_location)

            exprs = get!(merge_expressions_by_subcontext, target_subcontext, Expr[])
            preambles = get!(merge_preambles_by_subcontext, target_subcontext, Expr[])
            writeback_preambles, writeback_exprs = _subcontext_view_writeback_exprs(target_location, target_subcontext, algo_varname)
            append!(preambles, writeback_preambles)
            append!(exprs, writeback_exprs)

        elseif demand_all || algo_varname in demanded_runtime_names # New demanded variable so add it to this subcontext's runtime bucket.
            exprs = get!(runtime_expressions_by_subcontext, SubKey, Expr[])
            push!(
                exprs,
                Expr(:(=), subcontext_varname, :(getproperty(args, $(QuoteNode(algo_varname))))),
            )
        end
    end

    # Build the NamedTuple expressions for real subcontext writes and runtime
    # field patches. These create:
    #   (; subcontext1 = (; var1 = ...), ...)

    merge_subcontext_exprs = map(collect(merge_expressions_by_subcontext)) do (subctx, field_exprs)
        merge_expr = Expr(:tuple, Expr(:parameters, field_exprs...))
        preambles = get(merge_preambles_by_subcontext, subctx, Expr[])
        if !isempty(preambles)
            merge_expr = quote
                $(preambles...)
                $merge_expr
            end
        end
        return Expr(:(=), subctx, merge_expr)
    end
    runtime_subcontext_exprs = [
        Expr(:(=), subctx, Expr(:tuple, Expr(:parameters, field_exprs...)))
        for (subctx, field_exprs) in runtime_expressions_by_subcontext
    ]
    return (
        Expr(:tuple, Expr(:parameters, merge_subcontext_exprs...)),
        Expr(:tuple, Expr(:parameters, runtime_subcontext_exprs...)),
    )
end

"""
    _reverse_transform_component(value, Val(name), Val(index))

Return one backing-field value from a reverse transform result. Tuple results are
interpreted in route-source order; named-tuple results are read by backing name.
"""
@inline _reverse_transform_component(value::NT, ::Val{name}, ::Val{index}) where {NT<:NamedTuple,name,index} =
    getproperty(value, name)

@inline _reverse_transform_component(value::T, ::Val{name}, ::Val{index}) where {T<:Tuple,name,index} =
    getfield(value, index)

"""
    _subcontext_view_writeback_exprs(location, target_subcontext, algo_varname)

Build preamble and named-tuple field expressions that write one returned view
field back into its backing subcontext location.
"""
function _subcontext_view_writeback_exprs(target_location::VL, target_subcontext::Symbol, algo_varname::Symbol) where {VL<:VarLocation}
    targetname = get_originalname(target_location)
    forward_func = getfunc(target_location)
    reverse_func = getreversefunc(target_location)
    returned_expr = :(getproperty(args, $(QuoteNode(algo_varname))))

    if isnothing(reverse_func)
        if !isnothing(forward_func) || targetname isa Tuple
            error("Algorithm returned transformed variable $(algo_varname), but its route to $(target_subcontext).$(targetname) has no reverse_transform.")
        end

        return Expr[], [_subcontext_view_writeback_field_expr(target_subcontext, targetname, returned_expr)]
    end

    if targetname isa Tuple
        reverse_values = gensym(:reverse_values)
        preambles = [Expr(:(=), reverse_values, Expr(:call, reverse_func, returned_expr))]
        field_exprs = [
            _subcontext_view_writeback_field_expr(
                target_subcontext,
                targetname[i],
                :(@inline _reverse_transform_component($reverse_values, Val($(QuoteNode(targetname[i]))), Val($i))),
            )
            for i in eachindex(targetname)
        ]
        return preambles, field_exprs
    end

    write_value = Expr(:call, reverse_func, returned_expr)
    return Expr[], [_subcontext_view_writeback_field_expr(target_subcontext, targetname, write_value)]
end

"""
    _subcontext_view_writeback_field_expr(target_subcontext, targetname, value_expr)

Build the named-tuple field expression for one backing variable writeback.
"""
function _subcontext_view_writeback_field_expr(target_subcontext::Symbol, targetname::Symbol, value_expr::Expr)
    # Let the current stored value decide how an algorithm return is written
    # back. Plain fields use the returned value directly; wrapper fields can
    # absorb the write while preserving context shape.
    return Expr(
        :(=),
        targetname,
        :(@inline subcontext_writeback_value(
            (@inline storedproperty_fromsubcontext(scv, Val($(QuoteNode(target_subcontext))), Val($(QuoteNode(targetname))))),
            $value_expr,
        )),
    )
end

"""Merge with every non-state return field demanded."""
@inline function Base.merge(scv::SubContextView{CType, SubKey}, args::NamedTuple) where {CType<:ProcessContext, SubKey}
    return @inline merge(scv, args, ReturnDemand{fieldnames(typeof(args))}())
end

"""
Merge a step/init/cleanup return into persistent state and loop-local runtime state.
"""
@inline @generated function Base.merge(scv::SubContextView{CType, SubKey}, args::NamedTuple, demand::ReturnDemand{Names}) where {CType<:ProcessContext, SubKey, Names}
    mergetuple_expr, runtimetuple_expr = _subcontext_view_merge_exprs(scv, args, Names)

    # Return the expression that does the merge
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        mergetuple = $mergetuple_expr
        newcontext = merge_into_subcontexts(getcontext(scv), mergetuple)
        @assert typeof(newcontext) == typeof(getcontext(scv)) "A variable type in a subcontext was changed. This is prohibited for performance reasons.\nIf type mutation is needed, set the variable up as a Ref\n$(sprint(show, ContextTypeDiff(getcontext(scv), newcontext)))"
        runtimetuple = $runtimetuple_expr
        newruntimecontext = @inline merge_runtime_subcontexts(getruntimecontext(scv), runtimetuple)
        return newcontext, newruntimecontext
    end
end

"""
Instead of merging, replace the subcontext entirely with the provided args named tuple
Returns new context

This is to be used during the init phase, where entire subcontexts are replaced
"""
@inline @generated function Base.replace(scv::SubContextView{CType, SubKey}, args::NamedTuple) where {CType<:ProcessContext, SubKey}
    names = fieldnames(args)
    if any( n -> n != SubKey, names) # Static check that only the correct subcontext is being replaced
        error("Trying to replace subcontext $(n) from SubContextView $(SubKey), only $(SubKey) can be replaced")
    end

    return quote
        old_context = @inline getcontext(scv)
        return replace(old_context, (; SubKey => getproperty(args, SubKey)))
    end
end
