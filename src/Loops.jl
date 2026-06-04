const start_finished = Ref(false)

@inline function before_while(p::P) where {P<:AbstractProcess}
    start_finished[] = true
    p.threadid = Threads.threadid()
    set_starttime!(p)
end

@inline function before_while(ip::IP) where {IP<:InlineProcess}
    @inline set_starttime!(ip)
end

"""
    finalizer!(func, context, runtimecontext, process, lifetime)

Run cleanup and the final result projection while the loop-local runtime context
is still visible. The runtime context is intentionally not returned.
"""
@inline function finalizer!(func::F, context::C, runtimecontext::RC, process::P, lifetime::LT) where {F,C<:ProcessContext,RC<:ProcessContext,P<:AbstractProcess,LT<:Lifetime}
    runtimecontext = @inline _merge_into_globals(runtimecontext, (; process, lifetime))
    cleaned_context, cleaned_runtimecontext = @inline cleanup(func, context, runtimecontext)
    final_context = @inline final_visible_context(cleaned_context, cleaned_runtimecontext)
    return cleaned_context, (@inline _loop_final_result(func, final_context, cleaned_runtimecontext))
end

"""Build the loop-local runtime context for one execution."""
@inline function _initial_runtime_context(inputs::NamedTuple, process::P, lifetime::LT) where {P<:AbstractProcess,LT<:Lifetime}
    runtime = @inline _merge_into_globals(_empty_context(), (; process, lifetime))
    return isempty(inputs) ? runtime : @inline with_subcontext(runtime, Val(:_input), SubContext(:_input, inputs))
end

"""Build the visible paused context that keeps runtime inputs for resuming."""
@inline function _paused_visible_context(context::C, runtimecontext::RC) where {C<:ProcessContext,RC<:ProcessContext}
    inputs = @inline getruntimeinput(runtimecontext)
    return isempty(inputs) ? context : @inline with_subcontext(context, Val(:_input), SubContext(:_input, inputs))
end

"""Clear pause-only runtime inputs before re-entering the hot loop."""
@inline function _paused_state_context(context::C) where {C<:ProcessContext}
    return haskey(get_subcontexts(context), :_input) ? (@inline with_subcontext(context, Val(:_input), SubContext(:_input, (;)))) : context
end

@inline _loop_state_context(stored_context::C, ::Resuming{false}) where {C<:ProcessContext} = stored_context
@inline _loop_state_context(stored_context::C, ::Resuming{true}) where {C<:ProcessContext} = @inline _paused_state_context(stored_context)

@inline function _loop_runtime_context(inputs::NamedTuple, process::P, lifetime::LT, stored_context::C, ::Resuming{false}) where {P<:AbstractProcess,LT<:Lifetime,C<:ProcessContext}
    return @inline _initial_runtime_context(inputs, process, lifetime)
end

@inline function _loop_runtime_context(inputs::NamedTuple, process::P, lifetime::LT, stored_context::C, ::Resuming{true}) where {P<:AbstractProcess,LT<:Lifetime,C<:ProcessContext}
    runtime_inputs = @inline getruntimeinput(stored_context)
    return @inline _initial_runtime_context(runtime_inputs, process, lifetime)
end

"""Return whether this loop exit is a pause rather than a final completion."""
@inline _loop_ispaused(process::P) where {P<:AbstractProcess} = false
@inline _loop_ispaused(process::P) where {P<:Process} = ispaused(process)

"""Build the root wiring view for one loop execution."""
@inline _root_wiring_view(algo, step_plan) = PlanWiringView(getwiring(step_plan), Val(()), _finalstep_demands_all_returns(algo))

"""Commit or return the persistent context produced by the loop."""
@inline function after_while(p::P, func::F, context::C, runtimecontext::RC, returnvalue, stored_context::SC = context) where {P<:Process,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(p)
    if ispaused(p)
        paused_context = @inline _paused_visible_context(context, runtimecontext)
        _store_runtime_context!(p, paused_context)
        return paused_context
    end
    commit_context!(p, context)
    return returnvalue
end

@inline function after_while(ip::IP, func::F, context::C, runtimecontext::RC, returnvalue, stored_context::SC = context) where {IP<:InlineProcess,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(ip)
    StatefulAlgorithms.context(ip, context)
    return returnvalue
end

@inline function after_while(p::P, func::F, context::C, runtimecontext::RC, returnvalue, stored_context::SC = context) where {P<:LoopRunProcess,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(p)
    return context
end

"""
Run a single function in a loop indefinitely.
"""
@inline loop(process::P, func::F, context::C, lt::LT, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {P<:AbstractProcess, F, C, LT} =
    loop(process, func, context, lt, inputs, resume, sys_looptype)

@inline function loop(process::P, func::F, stored_context::C, lifetime::LT, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {P<:AbstractProcess,F<:AbstractLoopAlgorithm,C<:ProcessContext,LT<:IndefiniteLifetime,isresuming}
    @inline before_while(process)

    step_plan = @inline getplan(func)
    step_wiring = @inline _root_wiring_view(func, step_plan)
    resume = Resuming{isresuming}()
    context = @inline _loop_state_context(stored_context, resume)
    runtimecontext = @inline _loop_runtime_context(inputs, process, lifetime, stored_context, resume)

    if isresuming
        @atomic process.paused = false
    else
        context, runtimecontext = @inline _step!(step_plan, context, runtimecontext, step_wiring, Namespace{nothing}(), process, lifetime)
        @inline tick!(process)
        @inline inc!(process)
    end

    while true
        context, runtimecontext = @inline _step!(step_plan, context, runtimecontext, step_wiring, Namespace{nothing}(), process, lifetime)
        @inline tick!(process)
        @inline inc!(process)
        if @inline breakcondition(lifetime, process, context)
            break
        end
    end

    if @inline _loop_ispaused(process)
        return @inline after_while(process, func, context, runtimecontext, context, stored_context)
    end

    final_runtimecontext = runtimecontext
    context, returnvalue = @inline finalizer!(func, context, runtimecontext, process, lifetime)
    return @inline after_while(process, func, context, final_runtimecontext, returnvalue, stored_context)
end

"""
Run a single function in a loop for a given number of times.
"""
@inline loop(process::P, algo::F, context::C, r::R, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {P<:AbstractProcess, F, C, R <: RepeatLifetime} =
    loop(process, algo, context, r, inputs, resume, sys_looptype)

Base.@constprop :aggressive @inline function loop(process::P, algo::F, stored_context::C, lifetime::R, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {P<:AbstractProcess,F<:AbstractLoopAlgorithm,C<:ProcessContext,R<:RepeatLifetime,isresuming}
    @DebugMode "Running process loop for $repeats times from thread $(Threads.threadid())"
    @assert isresolved(algo) "Algo must be resolved before running the loop. Got algo $(algo) which is not resolved."
    @inline before_while(process)
    
    step_plan = @inline getplan(algo)
    step_wiring = @inline _root_wiring_view(algo, step_plan)
    resume = Resuming{isresuming}()
    context = @inline _loop_state_context(stored_context, resume)
    runtimecontext = @inline _loop_runtime_context(inputs, process, lifetime, stored_context, resume)

    if isresuming
        @atomic process.paused = false
    else
        context, runtimecontext = @inline _step!(step_plan, context, runtimecontext, step_wiring, Namespace{nothing}(), process, lifetime)
        @inline tick!(process)
        @inline inc!(process)
    end

    for _ in (@inline loopidx(process)):(@inline repeats(lifetime))
        context, runtimecontext = @inline _step!(step_plan, context, runtimecontext, step_wiring, Namespace{nothing}(), process, lifetime)
        @inline tick!(process)
        @inline inc!(process)
        if @inline breakcondition(lifetime, process, context)
            break
        end
    end

    if @inline _loop_ispaused(process)
        return @inline after_while(process, algo, context, runtimecontext, context, stored_context)
    end

    final_runtimecontext = runtimecontext
    context, returnvalue = @inline finalizer!(algo, context, runtimecontext, process, lifetime)
    return @inline after_while(process, algo, context, final_runtimecontext, returnvalue, stored_context)
end
