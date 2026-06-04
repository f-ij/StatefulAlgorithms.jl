@inline function _worker_option_endpoint_name(::Type{A}) where {A<:AbstractIdentifiableAlgo}
    return getkey(A)
end

@inline _worker_option_endpoint_name(::Type) = nothing

function _worker_graph_specs(::Type{DCA}) where {DCA<:DaggerCompositeAlgorithm}
    n = numalgos(DCA)
    child_names = ntuple(i -> getkey(getalgotype(DCA, i)), n)
    parents = [Int[] for _ in 1:n]
    option_tuple_type = DCA.parameters[4]
    option_types = option_tuple_type <: Tuple ? option_tuple_type.parameters : (option_tuple_type,)
    readonly_option_idxs = readonlyrouteindices(DCA)

    for (opt_idx, opt_type) in enumerate(option_types)
        route_type = _worker_route_type(opt_type)
        isnothing(route_type) && continue
        opt_idx in readonly_option_idxs && continue

        from_type = route_type.parameters[1]
        to_type = route_type.parameters[2]
        from_name = _worker_option_endpoint_name(from_type)
        to_name = _worker_option_endpoint_name(to_type)
        (from_name isa Symbol && to_name isa Symbol) || continue

        parent_idx = findfirst(==(from_name), child_names)
        child_idx = findfirst(==(to_name), child_names)
        if !isnothing(parent_idx) && !isnothing(child_idx) && parent_idx != child_idx && !(parent_idx in parents[child_idx])
            push!(parents[child_idx], parent_idx)
        end
    end

    remaining = collect(1:n)
    done = Int[]
    nodes = Tuple{Int, Tuple}[]

    while !isempty(remaining)
        ready = Int[]
        for idx in remaining
            if all(parent -> parent in done, parents[idx])
                push!(ready, idx)
            end
        end

        if isempty(ready)
            return [(idx, Tuple(1:(idx - 1))) for idx in 1:n]
        end

        for idx in ready
            push!(nodes, (idx, Tuple(sort(parents[idx]))))
        end

        append!(done, ready)
        filter!(idx -> !(idx in ready), remaining)
    end

    return nodes
end

@inline function _worker_should_run(dca::DaggerCompositeAlgorithm, this_inc::Int, idx::Int)
    this_interval = interval(dca, idx)
    return this_interval == 1 || this_inc % this_interval == 0
end

Base.@constprop :aggressive function _worker_run_reduced(sa::SA, reduced::RV, deltas::Vararg{Any,N}) where {SA<:AbstractIdentifiableAlgo, RV<:ReducedView, N}
    reduced_with_deltas = isempty(deltas) ? reduced : (@inline merge_into_reduced(SA, reduced, deltas...))
    retval = @inline step!(getalgo(sa), reduced_with_deltas)
    return if retval === nothing || (retval isa NamedTuple && isempty(retval))
        reduced_with_deltas
    else
        @inline merge_locals(SA, reduced_with_deltas, retval)
    end
end

Base.@constprop :aggressive function _worker_spawn_task(sa::SA, reduced::RV, deltas::Vararg{Any,N}) where {SA<:AbstractIdentifiableAlgo, RV<:ReducedView, N}
    return Threads.@spawn _worker_run_reduced(sa, reduced, deltas...)
end

@inline function _worker_parent_arg_expr(parent::Int)
    result_sym = Symbol(:result_, parent)
    return :($result_sym === nothing ? nothing : fetch($result_sym))
end

@inline function _worker_spawn_node_expr(idx::Int, parents::Tuple)
    reduced_sym = Symbol(:reduced_, idx)
    args = Any[:(getalgo(dca, $idx)), reduced_sym]
    append!(args, [_worker_parent_arg_expr(parent) for parent in parents])
    return :(_worker_spawn_task($(args...)))
end

function _worker_run_graph_expr(::Type{DCA}, ::Type{C}; pretty = false) where {DCA<:DaggerCompositeAlgorithm, C<:ProcessContext}
    specs = _worker_graph_specs(DCA)
    exprs = Any[]

    for (idx, _) in specs
        reduced_sym = Symbol(:reduced_, idx)
        push!(exprs, :($reduced_sym = ReducedView(base_context, getalgo(dca, $idx))))
    end

    for (idx, parents) in specs
        result_sym = Symbol(:result_, idx)
        spawn_expr = _worker_spawn_node_expr(idx, parents)
        push!(exprs, :($result_sym = _worker_should_run(dca, this_inc, $idx) ? $spawn_expr : nothing))
    end

    push!(exprs, :(merged_updates = (;)))

    for (idx, _) in specs
        result_sym = Symbol(:result_, idx)
        child_name = getkey(getalgotype(DCA, idx))
        payload_type = getdatatype(subcontext_type(C, child_name))
        update_type = NamedTuple{(child_name,), Tuple{payload_type}}
        push!(exprs, quote
            if $result_sym !== nothing
                local reduced = fetch($result_sym)
                local local_values = getlocals(reduced)
                local update = $update_type((local_values,))
                merged_updates = merge(merged_updates, update)
            end
        end)
    end

    push!(exprs, :(isempty(merged_updates) ? base_context : merge_into_subcontexts(base_context, merged_updates)))
    return Expr(:block, exprs...)
end

function _worker_graph_results_expr(::Type{DCA}; pretty = false) where {DCA<:DaggerCompositeAlgorithm}
    specs = _worker_graph_specs(DCA)
    exprs = Any[]
    result_syms = Symbol[]

    for (idx, _) in specs
        reduced_sym = Symbol(:reduced_, idx)
        push!(exprs, :($reduced_sym = ReducedView(base_context, getalgo(dca, $idx))))
    end

    for (idx, parents) in specs
        result_sym = Symbol(:result_, idx)
        push!(result_syms, result_sym)
        spawn_expr = _worker_spawn_node_expr(idx, parents)
        push!(exprs, :($result_sym = _worker_should_run(dca, this_inc, $idx) ? $spawn_expr : nothing))
    end

    push!(exprs, Expr(:tuple, result_syms...))
    return Expr(:block, exprs...)
end

@generated function _worker_run_graph(base_context::C, dca::DCA, this_inc::Int) where {C<:ProcessContext, DCA<:DaggerCompositeAlgorithm}
    return _worker_run_graph_expr(DCA, C; pretty = false)
end

"""
Run the routed graph as a straight-line sequence of `Threads.@spawn` calls. Parent task
results are fetched only inside dependent tasks, not on the coordinator thread. The
coordinator only performs the final merge boundary back into the canonical process
context.

Future direction:
- Profile one mock step per child algorithm on a fully initialized mock context,
- capture the concrete `NamedTuple` return type for each child,
- then rebuild the worker child view around those profiled writeback types so the merged
  context facade stays concrete without relying on the current eager `ReducedView`.
"""
Base.@constprop :aggressive function step!(dca::DaggerCompositeAlgorithm, context::C) where {C<:ProcessContext}
    this_inc = inc(dca)
    current = @inline _worker_run_graph(context, dca, this_inc)
    inc!(dca)
    return current
end
