
"""
Whether a step in namespace `own` may write the runtime value under `target`: a declared local, a captured return (a
value of the block an algorithm updates, see `@update`), or its own outputs. Inputs are read-only.
"""
_writable_runtime(::Union{DeclaredLocals, CapturedReturns}, target::Symbol, own::Symbol) = true
_writable_runtime(::ContextPartition, target::Symbol, own::Symbol) = target === own

"""A step that returns `nothing` changes nothing: the view's bundle as it was."""
@inline Base.merge(scv::SubContextView, ::Nothing) = @inline getbundle(scv)

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

    write_preambles = Expr[]
    write_requests = Expr[]
    runtime_expressions_by_subcontext = Dict{Symbol, Vector{Expr}}()

    for (var_idx, algo_varname) in enumerate(algo_varnames)
        target_location, subcontext_varname = _compute_location(SCV, algo_varname)
        # First look if varname is in locations
        if target_location isa VarLocation{:runtime}  # a runtime location: declared locals and this step's own outputs are writable
            target_subcontext = get_subcontextname(target_location)
            targetname = location_fieldname(target_location)
            _writable_runtime(context_partition(Val(target_subcontext)), target_subcontext, SubKey) || error("An algorithm writes back `$(algo_varname)`, which it reads from `$(target_subcontext)`: that is read-only.")
            exprs = get!(runtime_expressions_by_subcontext, target_subcontext, Expr[])
            # Converted to the slot's type by `merge_runtime_return(…, Val(target_subcontext), …)`.
            push!(exprs, Expr(:(=), targetname, :(getproperty(args, $(QuoteNode(algo_varname))))))
        elseif !isnothing(target_location) # If the local variable exists
            preambles, requests = _build_write_request_exprs(target_location, algo_varname)
            append!(write_preambles, preambles)
            append!(write_requests, requests)

        elseif demand_all || algo_varname in demanded_runtime_names # A demanded name the view does not see: one of this namespace's own outputs.
            exprs = get!(runtime_expressions_by_subcontext, SubKey, Expr[])
            push!(
                exprs,
                Expr(:(=), subcontext_varname, :(getproperty(args, $(QuoteNode(algo_varname))))),
            )
        end
    end

    # The persistent writes: one `StoreInto` request per written field, followed by `_follow_writes` (ReadingWriting.jl) and
    # grouped into `(; subcontext1 = (; var1 = ...), ...)` by `_build_write_payload`.
    merge_expr = quote
        $(write_preambles...)
        @inline _build_write_payload(@inline _follow_writes(scv, ($(write_requests...),)))
    end
    runtime_subcontext_exprs = [
        Expr(:(=), subctx, Expr(:tuple, Expr(:parameters, field_exprs...)))
        for (subctx, field_exprs) in runtime_expressions_by_subcontext
    ]
    return (
        merge_expr,
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
    _build_write_request_exprs(location, algo_varname)

Return the preamble expressions and the `StoreInto` request expressions that write the returned `algo_varname` to the
view location `location`: one request for its field, or after a reverse transform one per field it reads.
"""
function _build_write_request_exprs(@nospecialize(target_location::VarLocation), algo_varname::Symbol)
    target_subcontext = get_subcontextname(target_location)
    targetname = location_fieldname(target_location)
    forward_func = getfunc(target_location)
    reverse_func = getreversefunc(target_location)
    returned_expr = :(getproperty(args, $(QuoteNode(algo_varname))))
    request_expr(field, value_expr) = :(StoreInto{$(typeof(VarLocation{:state}(target_subcontext, field)))}($value_expr))

    if isnothing(reverse_func)
        if !isnothing(forward_func) || targetname isa Tuple
            error("Algorithm returned transformed variable $(algo_varname), but its route to $(target_subcontext).$(targetname) has no reverse_transform.")
        end
        return Expr[], [request_expr(targetname, returned_expr)]
    end

    if targetname isa Tuple
        reverse_values = gensym(:reverse_values)
        preambles = [Expr(:(=), reverse_values, Expr(:call, reverse_func, returned_expr))]
        requests = [
            request_expr(targetname[i], :(@inline _reverse_transform_component($reverse_values, Val($(QuoteNode(targetname[i]))), Val($i))))
            for i in eachindex(targetname)
        ]
        return preambles, requests
    end

    return Expr[], [request_expr(targetname, Expr(:call, reverse_func, returned_expr))]
end

"""Merge with every non-state return field demanded."""
@inline function Base.merge(scv::SubContextView{B, SubKey}, args::NamedTuple) where {B<:ContextBundle, SubKey}
    return @inline merge(scv, args, ReturnDemand{fieldnames(typeof(args))}())
end

"""
    _build_merge_payload(scv, args, demand)

What `merge(scv, args, demand)` writes into the persistent context, as `(; subcontext = (; field = value, ...), ...)`.
"""
@inline @generated function _build_merge_payload(scv::SubContextView{B, SubKey}, args::NamedTuple, demand::ReturnDemand{Names}) where {B<:ContextBundle, SubKey, Names}
    mergetuple_expr, _ = _subcontext_view_merge_exprs(scv, args, Names)
    return mergetuple_expr
end

"""
Merge a step/init/cleanup return into the view's bundle: state into the persistent context, runtime values (declared locals,
outputs) into the runtime context. Returns the new bundle.
"""
@inline @generated function Base.merge(scv::SubContextView{B, SubKey}, args::NamedTuple, demand::ReturnDemand{Names}) where {B<:ContextBundle, SubKey, Names}
    _, runtimetuple_expr = _subcontext_view_merge_exprs(scv, args, Names)

    # Return the expression that does the merge
    return quote
        $(LineNumberNode(@__LINE__, @__FILE__))
        mergetuple = @inline _build_merge_payload(scv, args, demand)
        newcontext = merge_into_subcontexts(getpersistent(scv), mergetuple)
        @assert typeof(newcontext) == typeof(getpersistent(scv)) "A variable type in a subcontext was changed. This is prohibited for performance reasons.\nIf type mutation is needed, set the variable up as a Ref\n$(sprint(show, ContextTypeDiff(getpersistent(scv), newcontext)))"
        runtimetuple = $runtimetuple_expr
        return @inline _rebundle(getbundle(scv), newcontext, runtimetuple)
    end
end

"""
Instead of merging, replace the subcontext entirely with the provided args named tuple
Returns new context

This is to be used during the init phase, where entire subcontexts are replaced
"""
@inline @generated function Base.replace(scv::SubContextView{B, SubKey}, args::NamedTuple) where {B<:ContextBundle, SubKey}
    names = fieldnames(args)
    if any( n -> n != SubKey, names) # Static check that only the correct subcontext is being replaced
        error("Trying to replace subcontext $(n) from SubContextView $(SubKey), only $(SubKey) can be replaced")
    end

    return quote
        old_context = @inline getpersistent(scv)
        return replace(old_context, (; SubKey => getproperty(args, SubKey)))
    end
end
