struct ThreadedIndex{idx} end
struct ThreadedLayer{Idxs} end

"""
Return threaded execution layers.

Threaded composites are deferred for the plan-wrapper route model, so
`SubContext` no longer carries route/share metadata for dependency sorting.
Until threaded plan wiring is implemented, children are emitted in one layer.
"""
@generated function _threaded_layers(::TCA, ::C) where {TCA<:ThreadedCompositeAlgorithm, C<:ProcessContext}
    n = numalgos(TCA)
    return :(($(Expr(:curly, :ThreadedLayer, Expr(:tuple, ntuple(identity, n)...)))(),))
end

@inline function _threaded_should_run(tca::ThreadedCompositeAlgorithm, this_inc::Int, idx::Int, context)
    this_interval = interval(tca, idx)
    return @inline should_run_schedule(this_interval, this_inc, context)
end

Base.@constprop :aggressive function threaded_step(sa::SA, base_context::C) where {SA<:AbstractIdentifiableAlgo, C<:ProcessContext}
    contextview = @inline view(base_context, sa)
    task = Threads.@spawn step!(getalgo(sa), contextview)
    return (sa, contextview, task)
end

Base.@constprop :aggressive function _threaded_run_child(base_context::C, tca::TCA, ::ThreadedIndex{idx}, this_inc::Int) where {C<:ProcessContext, TCA<:ThreadedCompositeAlgorithm, idx}
    if !(@inline _threaded_should_run(tca, this_inc, idx, base_context))
        return nothing
    end

    sa = @inline getalgo(tca, idx)
    contextview = @inline view(base_context, sa)
    retval = @inline step!(getalgo(sa), contextview)
    merged_context = @inline merge(contextview, retval)
    local_payload = @inline getdata(getproperty(merged_context, getkey(sa)))
    child_name = getkey(getalgotype(TCA, idx))
    return NamedTuple{(child_name,), Tuple{getdatatype(subcontext_type(C, child_name))}}((local_payload,))
end

Base.@constprop :aggressive function _threaded_spawn_child(base_context::C, tca::TCA, ::ThreadedIndex{idx}, this_inc::Int) where {C<:ProcessContext, TCA<:ThreadedCompositeAlgorithm, idx}
    if !(@inline _threaded_should_run(tca, this_inc, idx, base_context))
        return nothing
    end
    sa = @inline getalgo(tca, idx)
    return @inline threaded_step(sa, base_context)
end

Base.@constprop :aggressive function _threaded_merge_child_payload(merged::NamedTuple, future, ::Type{C}, ::Type{TCA}, idx::ThreadedIndex{idx_val}) where {C<:ProcessContext, TCA<:ThreadedCompositeAlgorithm, idx_val}
    if future === nothing
        return merged
    end
    sa, contextview, task = future
    retval = @inline fetch(task)
    merged_context = @inline merge(contextview, retval)
    local_payload = @inline getdata(getproperty(merged_context, getkey(sa)))
    child_name = getkey(getalgotype(TCA, idx_val))
    payload = NamedTuple{(child_name,), Tuple{getdatatype(subcontext_type(C, child_name))}}((local_payload,))
    return @inline merge(merged, payload)
end

Base.@constprop :aggressive function _threaded_run_layer(base_context::C, tca::TCA, ::ThreadedLayer{Idxs}, this_inc::Int) where {C<:ProcessContext, TCA<:ThreadedCompositeAlgorithm, Idxs}
    children = ntuple(i -> ThreadedIndex{Idxs[i]}(), length(Idxs))
    isempty(children) && return base_context

    if length(children) == 1
        merged_children = @inline _threaded_run_child(base_context, tca, getfield(children, 1), this_inc)
        isnothing(merged_children) && return base_context
        return (@inline merge_into_subcontexts(base_context, merged_children))::C
    end

    futures = ntuple(Val(length(children))) do i
        @inline _threaded_spawn_child(base_context, tca, getfield(children, i), this_inc)
    end

    child_futures = ntuple(Val(length(children))) do i
        (getfield(children, i), getfield(futures, i))
    end

    merged_children = unrollreplace((;), child_futures) do merged, child_future
        child, future = child_future
        @inline _threaded_merge_child_payload(merged, future, C, TCA, child)
    end

    isempty(merged_children) && return base_context
    return (@inline merge_into_subcontexts(base_context, merged_children))::C
end

Base.@constprop :aggressive function step!(tca::ThreadedCompositeAlgorithm, context::C) where {C<:ProcessContext}
    cursor = loop_cursor(tca, Val(false))
    this_inc = inc(cursor, tca)
    layers = @inline _threaded_layers(tca, context)

    current = @inline unrollreplace(context, layers) do current, layer
        @inline _threaded_run_layer(current, tca, layer, this_inc)::C
    end
    inc!(cursor, tca)
    return current
end

Base.@constprop :aggressive @inline @generated function _step!(tca::TCA, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N, process::P, lifetime::LT) where {TCA <: ThreadedCompositeAlgorithm, S<:CompositeLoopCursor, C <: AbstractContext, RC <: ProcessContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(TCA)
    schedule_values = TCA.parameters[2]
    child_namespace_tuple_type = TCA.parameters[3]

    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(tca)))
    push!(exprs, :(local this_inc = @inline inc(cursor, tca)))

    for i in 1:algo_count
        schedule_value = schedule_values[i]
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        push!(exprs, quote
            if @inline should_run_schedule($schedule_value, this_inc, context)
                local algo = @inline getfield(algos, $i)
                local child_cursor = @inline child_loop_cursor(cursor, Val($i))
                local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
                local child_namespace = $child_namespace_type()
                context, runtimecontext = @inline _step!(algo, child_cursor, context, runtimecontext, child_step_wiring, child_namespace, process, lifetime)
            end
        end)
    end

    push!(exprs, :(@inline inc!(cursor, tca)))
    push!(exprs, :(return context, runtimecontext))
    return Expr(:block, exprs...)
end
