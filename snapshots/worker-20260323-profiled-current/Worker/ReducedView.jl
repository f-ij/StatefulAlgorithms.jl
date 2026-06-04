"""
Flat worker-only child context.

`ReducedView` materializes the full visible variable set for one child into one flat
`NamedTuple`. Overwrite state is tracked separately by a fixed-layout tuple of `Bool`s in
the same field order as `vars`.

Design note:
- The current worker backend uses this eager flattened view because the schema is fixed at
  construction time, so merges only overwrite existing slots.
- A future version should try a profiled typed context wrapper instead:
  - run one mock step on a fully initialized mock context,
  - record the concrete returned `NamedTuple` shape for each child algorithm,
  - rebuild a context wrapper using those profiled writeback types so the merged view can
    stay concrete without eagerly materializing all visible keys up front.
"""
struct ReducedView{CType, Owner, Vars, Flags, LocalNames} <: AbstractContext
    vars::Vars
    overwritten::Flags
end

@inline Base.keys(rv::ReducedView) = propertynames(getfield(rv, :vars))
@inline Base.propertynames(rv::ReducedView) = propertynames(getfield(rv, :vars))
@inline Base.haskey(rv::ReducedView, name::Symbol) = haskey(getfield(rv, :vars), name)
@inline Base.hasproperty(rv::ReducedView, name::Symbol) = hasproperty(getfield(rv, :vars), name)
@inline function Base.get(rv::ReducedView, name::Symbol, default)
    return haskey(rv, name) ? getproperty(rv, name) : default
end

@inline function Base.getproperty(rv::ReducedView, name::Symbol)
    name === :vars && return getfield(rv, :vars)
    name === :overwritten && return getfield(rv, :overwritten)
    return getproperty(getfield(rv, :vars), name)
end

@inline function getlocals(rv::ReducedView{CType, Owner, Vars, Flags, LocalNames}) where {CType<:ProcessContext, Owner, Vars, Flags, LocalNames}
    return NamedTuple{LocalNames}(ntuple(i -> getproperty(getfield(rv, :vars), LocalNames[i]), length(LocalNames)))
end

@inline _worker_writeback_name(sa::Union{SA, Type{SA}}, name::Symbol) where {SA<:AbstractIdentifiableAlgo} = algo_to_subcontext_names(varaliases(SA), name)

@inline function _worker_reduced_value_expr(rv_expr, location, target_type)
    original_names = get_originalname(location)
    original_names = original_names isa Tuple ? original_names : (original_names,)
    source_exprs = [:(getproperty(getfield($rv_expr, :vars), $(QuoteNode(original_name)))) for original_name in original_names]
    func = getfunc(location)
    value_expr = isnothing(func) ? source_exprs[1] : Expr(:call, func, source_exprs...)
    return :(convert($target_type, $value_expr))
end

@inline Base.merge(rv::ReducedView, ::Nothing) = rv

Base.@constprop :aggressive @generated function merge_locals(::Type{SA}, rv::ReducedView{CType, Owner, Vars, Flags, LocalNames}, args::NamedTuple) where {CType<:ProcessContext, SA<:AbstractIdentifiableAlgo, Owner, Vars, Flags, LocalNames}
    visible_names = fieldnames(Vars)
    local_names = Tuple(LocalNames)
    ret_names = fieldnames(args)
    value_exprs = Any[]
    flag_exprs = Any[]

    local_update_indices = Dict{Int, Expr}()
    for ret_name in ret_names
        sub_name = _worker_writeback_name(SA, ret_name)
        sub_name in local_names || return :(error("Worker ReducedView only supports returning local child variables for $(SA)"))
        idx = findfirst(==(sub_name), visible_names)
        isnothing(idx) && return :(error("Worker ReducedView could not find visible location $(sub_name) for $(SA)"))
        local_update_indices[idx] = :(convert($(fieldtype(Vars, sub_name)), getproperty(args, $(QuoteNode(ret_name)))))
    end

    for (idx, name) in enumerate(visible_names)
        push!(value_exprs, get(local_update_indices, idx, :(getproperty(getfield(rv, :vars), $(QuoteNode(name))))))
        push!(flag_exprs, haskey(local_update_indices, idx) ? :(true) : :(getfield(getfield(rv, :overwritten), $idx)))
    end

    return quote
        new_vars = NamedTuple{$visible_names}(tuple($(value_exprs...)))
        new_flags = tuple($(flag_exprs...))
        ReducedView{CType, Owner, Vars, Flags, LocalNames}(new_vars, new_flags)
    end
end

@inline merge_into_reduced(::Type{SA}, rv::ReducedView, parents...) where {SA<:AbstractIdentifiableAlgo} = _merge_into_reduced_tuple(SA, rv, parents)

Base.@constprop :aggressive @generated function _merge_into_reduced_tuple(::Type{SA}, rv::ReducedView{CType, Owner, Vars, Flags, LocalNames}, parents::Parents) where {CType<:ProcessContext, SA<:AbstractIdentifiableAlgo, Owner, Vars, Flags, LocalNames, Parents<:Tuple}
    subkey = getkey(SA)
    scv_type = SubContextView{CType, subkey, SA, NamedTuple{(), Tuple{}}, varaliases(SA)}
    locations = get_all_locations(scv_type)
    visible_names = propertynames(locations)
    parent_types = Parents.parameters
    value_exprs = Any[]
    flag_exprs = Any[]

    for (idx, name) in enumerate(visible_names)
        location = getproperty(locations, name)
        value_expr = :(getproperty(getfield(rv, :vars), $(QuoteNode(name))))
        flag_expr = :(getfield(getfield(rv, :overwritten), $idx))
        target_type = fieldtype(Vars, name)
        target_subcontext = get_subcontextname(location)

        for parent_idx in 1:length(parent_types)
            parent_type = parent_types[parent_idx]
            parent_type <: ReducedView || continue
            parent_owner = parent_type.parameters[2]
            parent_owner == target_subcontext || continue

            parent_vars = parent_type.parameters[3]
            parent_names = fieldnames(parent_vars)
            original_names = get_originalname(location)
            original_names = original_names isa Tuple ? original_names : (original_names,)
            all(original_name -> original_name in parent_names, original_names) || continue

            parent_expr = :(getfield(parents, $parent_idx))
            parent_flag_checks = Expr[]
            for original_name in original_names
                parent_flag_idx = findfirst(==(original_name), parent_names)
                push!(parent_flag_checks, :(getfield(getfield($parent_expr, :overwritten), $parent_flag_idx)))
            end
            candidate_flag = foldl((lhs, rhs) -> :($lhs && $rhs), parent_flag_checks)
            candidate_value = _worker_reduced_value_expr(parent_expr, location, target_type)
            value_expr = :($candidate_flag ? $candidate_value : $value_expr)
            flag_expr = :($candidate_flag ? true : $flag_expr)
        end

        push!(value_exprs, value_expr)
        push!(flag_exprs, flag_expr)
    end

    return quote
        new_vars = NamedTuple{$visible_names}(tuple($(value_exprs...)))
        new_flags = tuple($(flag_exprs...))
        ReducedView{CType, Owner, Vars, Flags, LocalNames}(new_vars, new_flags)
    end
end

@inline function ReducedView(pc::C, sa::SA) where {C<:ProcessContext, SA<:AbstractIdentifiableAlgo}
    return @inline ReducedView(view(pc, sa))
end

@inline @generated function ReducedView(scv::SCV) where {SCV<:SubContextView{CType, SubKey, SA}} where {CType<:ProcessContext, SubKey, SA<:AbstractIdentifiableAlgo}
    locations = get_all_locations(SCV)
    visible_names = propertynames(locations)
    local_names = fieldnames(getdatatype(subcontext_type(CType, SubKey)))
    value_exprs = [:(getproperty(scv, $(getproperty(locations, name)))) for name in visible_names]
    overwritten_expr = Expr(:tuple, fill(false, length(visible_names))...)

    return quote
        vars = NamedTuple{$visible_names}(tuple($(value_exprs...)))
        overwritten = $overwritten_expr
        ReducedView{CType, SubKey, typeof(vars), typeof(overwritten), $local_names}(vars, overwritten)
    end
end
