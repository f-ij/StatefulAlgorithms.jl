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
    finalizer!(func, persistent_context, runtime_context, process, lifetime)

Run cleanup and build the final result (`finalstep` gets `final_context`) while the run's runtime values are still
there. Returns the persistent context and the result; the runtime values end with the run.
"""
@inline function finalizer!(func::F, persistent_context::C, runtime_context::RC, process::P, lifetime::LT) where {F,C<:ProcessContext,RC<:ProcessContext,P<:AbstractProcess,LT<:Lifetime}
    cleaned = @inline cleanup(func, LoopContext(persistent_context, runtime_context))
    return (@inline getpersistent(cleaned)), (@inline _loop_final_result(func, (@inline final_context(cleaned)), getruntime(cleaned)))
end

"""
Build the runtime context for one run: its inputs (`_inputs`) and declared locals (`_declared_locals`). Returns
(`_captured_returns`, `_subcontext_returns`) are not in it: a step adds them where they are assigned and removes them
when their plan node ends (see `LoopContext`), so every step gets and returns a runtime context of this type.

The process and the lifetime are not in it: no step read them (they were in `_captured_returns` until 2026-10). Init still gets
the lifetime, for sizing (`InitContext`, `processsizehint!`). To give steps loop information again (step
index, total steps, elapsed time, a stop request), add narrow read-only values here rather than the `Process` object,
which would tie step code to the process type; most of those uses belong in the plan (schedules, lifetimes) instead.
"""
@inline function _initial_runtime_context(inputs::NamedTuple, locals::NamedTuple = (;))
    runtime = @inline _empty_context()
    runtime = isempty(inputs) ? runtime : @inline with_subcontext(runtime, Val(:_inputs), SubContext{:_inputs}(inputs))
    return isempty(locals) ? runtime : @inline with_subcontext(runtime, Val(:_declared_locals), SubContext{:_declared_locals}(locals))
end

"""Build the visible paused context that keeps runtime inputs and declared locals for resuming."""
@inline function _paused_visible_context(persistent_context::C, runtime_context::RC) where {C<:ProcessContext,RC<:ProcessContext}
    inputs = @inline get_inputs(runtime_context)
    persistent_context = isempty(inputs) ? persistent_context : @inline with_subcontext(persistent_context, Val(:_inputs), SubContext{:_inputs}(inputs))
    locals = @inline get_declared_locals(runtime_context)
    return isempty(locals) ? persistent_context : @inline with_subcontext(persistent_context, Val(:_declared_locals), SubContext{:_declared_locals}(locals))
end

"""Clear pause-only runtime inputs and declared locals before re-entering the hot loop."""
@inline function _paused_state_context(persistent_context::C) where {C<:ProcessContext}
    # Written out per field: reassigning `persistent_context` in a loop would change its type per iteration.
    persistent_context = @inline _clear_paused_subcontext(persistent_context, Val(:_inputs))
    return @inline _clear_paused_subcontext(persistent_context, Val(:_declared_locals))
end

@inline _clear_paused_subcontext(persistent_context::C, ::Val{name}) where {C<:ProcessContext,name} =
    haskey(get_subcontexts(persistent_context), name) ? (@inline with_subcontext(persistent_context, Val(name), SubContext{name}((;)))) : persistent_context

@inline _loop_persistent_context(start_persistent_context::C, ::Resuming{false}) where {C<:ProcessContext} = start_persistent_context
@inline _loop_persistent_context(start_persistent_context::C, ::Resuming{true}) where {C<:ProcessContext} = @inline _paused_state_context(start_persistent_context)

@inline function _loop_runtime_context(algo::F, inputs::NamedTuple, process::P, lifetime::LT, start_persistent_context::C, ::Resuming{false}) where {F,P<:AbstractProcess,LT<:Lifetime,C<:ProcessContext}
    return @inline _initial_runtime_context(inputs, collect_tree_locals(algo))
end

@inline function _loop_runtime_context(algo::F, inputs::NamedTuple, process::P, lifetime::LT, start_persistent_context::C, ::Resuming{true}) where {F,P<:AbstractProcess,LT<:Lifetime,C<:ProcessContext}
    runtime_inputs = @inline get_inputs(start_persistent_context)
    return @inline _initial_runtime_context(runtime_inputs, get_declared_locals(start_persistent_context))
end

"""Return whether this loop exit is a pause rather than a final completion."""
@inline _loop_ispaused(process::P) where {P<:AbstractProcess} = false
@inline _loop_ispaused(process::P) where {P<:Process} = ispaused(process)

"""Build the root wiring view for one loop execution."""
@inline _root_wiring_view(algo, step_plan) = PlanWiringView(getwiring(step_plan))

"""Build or recover the per-run loop cursor for one execution."""
@inline _loop_cursor(process::AbstractProcess, plan, ::Resuming) = loop_cursor(plan, Val(false))

@inline function _loop_cursor(process::Process, plan, ::Resuming{IsResuming}) where {IsResuming}
    IsResuming && return @inline getloopcursor(process)
    return @inline loop_cursor(plan, Val(true))
end

"""
Keep the cursor on a pause so the next run resumes from it. It is stored only on
that exit, so while the loop runs the cursor never escapes and can stay in registers.
"""
@inline _keep_loop_cursor!(process::Process, cursor) = (process.loop_cursor = cursor; nothing)
@inline _keep_loop_cursor!(::AbstractProcess, cursor) = nothing

"""Commit or return the persistent context produced by the loop."""
@inline function after_while(p::P, func::F, persistent_context::C, runtime_context::RC, returnvalue, start_persistent_context::SC = persistent_context) where {P<:Process,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(p)
    if ispaused(p)
        paused_context = @inline _paused_visible_context(persistent_context, runtime_context)
        _store_runtime_context!(p, paused_context)
        return paused_context
    end
    commit_context!(p, persistent_context)
    p.loop_cursor = nothing
    return returnvalue
end

@inline function after_while(ip::IP, func::F, persistent_context::C, runtime_context::RC, returnvalue, start_persistent_context::SC = persistent_context) where {IP<:InlineProcess,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(ip)
    StatefulAlgorithms.context(ip, persistent_context)
    return returnvalue
end

@inline function after_while(p::P, func::F, persistent_context::C, runtime_context::RC, returnvalue, start_persistent_context::SC = persistent_context) where {P<:LoopRunProcess,F,C<:ProcessContext,RC<:ProcessContext,SC<:ProcessContext}
    @inline set_endtime!(p)
    return persistent_context
end

"""
Run a single function in a loop indefinitely.
"""
@inline loop(process::P, func::F, start_persistent_context::C, lt::LT, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {P<:AbstractProcess, F, C, LT} =
    loop(process, func, start_persistent_context, lt, inputs, resume, sys_looptype)

@inline function loop(process::P, func::F, start_persistent_context::C, lifetime::LT, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {P<:AbstractProcess,F<:AbstractLoopAlgorithm,C<:ProcessContext,LT<:IndefiniteLifetime,isresuming}
    @inline before_while(process)

    step_plan = @inline getplan(func)
    step_wiring = @inline _root_wiring_view(func, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(process, step_plan, resume)
    persistent_context = @inline _loop_persistent_context(start_persistent_context, resume)
    runtime_context = @inline _loop_runtime_context(func, inputs, process, lifetime, start_persistent_context, resume)

    isresuming && @atomic process.paused = false

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, LoopContext(persistent_context, runtime_context), step_wiring, Namespace{nothing}(), process, lifetime)
    carried, runtime_context = _run_steps(carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)
    persistent_context = @inline with_carried(persistent_context, carried)

    if @inline _loop_ispaused(process)
        @inline _keep_loop_cursor!(process, step_cursor)
        return @inline after_while(process, func, persistent_context, runtime_context, persistent_context, start_persistent_context)
    end

    final_runtime_context = runtime_context
    persistent_context, returnvalue = @inline finalizer!(func, persistent_context, runtime_context, process, lifetime)
    return @inline after_while(process, func, persistent_context, final_runtime_context, returnvalue, start_persistent_context)
end

"""
Run a single function in a loop for a given number of times.
"""
@inline loop(process::P, algo::F, start_persistent_context::C, r::R, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {P<:AbstractProcess, F, C, R <: RepeatLifetime} =
    loop(process, algo, start_persistent_context, r, inputs, resume, sys_looptype)

Base.@constprop :aggressive @inline function loop(process::P, algo::F, start_persistent_context::C, lifetime::R, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {P<:AbstractProcess,F<:AbstractLoopAlgorithm,C<:ProcessContext,R<:RepeatLifetime,isresuming}
    @DebugMode "Running process loop for $repeats times from thread $(Threads.threadid())"
    @assert isresolved(algo) "Algo must be resolved before running the loop. Got algo $(algo) which is not resolved."
    @inline before_while(process)
    
    step_plan = @inline getplan(algo)
    step_wiring = @inline _root_wiring_view(algo, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(process, step_plan, resume)
    persistent_context = @inline _loop_persistent_context(start_persistent_context, resume)
    runtime_context = @inline _loop_runtime_context(algo, inputs, process, lifetime, start_persistent_context, resume)

    isresuming && @atomic process.paused = false

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, LoopContext(persistent_context, runtime_context), step_wiring, Namespace{nothing}(), process, lifetime)
    carried, runtime_context = _repeat_steps((@inline loopidx(process)), carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)
    persistent_context = @inline with_carried(persistent_context, carried)

    if @inline _loop_ispaused(process)
        @inline _keep_loop_cursor!(process, step_cursor)
        return @inline after_while(process, algo, persistent_context, runtime_context, persistent_context, start_persistent_context)
    end

    final_runtime_context = runtime_context
    persistent_context, returnvalue = @inline finalizer!(algo, persistent_context, runtime_context, process, lifetime)
    return @inline after_while(process, algo, persistent_context, final_runtime_context, returnvalue, start_persistent_context)
end

"""
    _repeat_steps(i, carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)

Run steps `i` to `repeats(lifetime)` (until the process's stop check holds) and return the carried fields and the
runtime context after the last one. The steps run in a loop compiled for the runtime context's type; when a step
returns another type (a local declared without a type gets its first value, Locals.jl), the remaining steps continue in
a call compiled for that type, so the loop stays type-stable. Inlined into `loop` (as separate code, Routine plans ran
up to 1.9x slower); the call for a new type stays a call.
"""
@inline function _repeat_steps(i::IndexType, carried::CarriedType, runtime_context::RuntimeContextType, step_plan::PlanType, step_cursor::CursorType, persistent_context::PersistentContextType, step_wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {IndexType<:Integer, CarriedType, RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, ProcessType, LifetimeType}
    for j in i:(@inline repeats(lifetime))
        # The step's `LoopContext` is built from the pieces the loop carries, and taken apart again after it.
        stepped_lc = @inline _step!(step_plan, step_cursor, LoopContext((@inline with_carried(persistent_context, carried)), runtime_context), step_wiring, Namespace{nothing}(), process, lifetime)
        stepped_persistent_context, stepped_runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
        carried = @inline next_carried(carried, stepped_persistent_context)
        @inline tick!(process)
        @inline inc!(process)
        (@inline _process_breakcondition(lifetime, process, stepped_persistent_context)) && return carried, stepped_runtime_context
        stepped_runtime_context isa RuntimeContextType || return _repeat_steps(j + 1, carried, stepped_runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)
        runtime_context = stepped_runtime_context
    end
    return carried, runtime_context
end

"""
    _run_steps(carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)

Run steps until the process's stop check holds and return the carried fields and the runtime context after the
last one; a runtime context of another type continues in a call compiled for that type, as in `_repeat_steps`.
"""
@inline function _run_steps(carried::CarriedType, runtime_context::RuntimeContextType, step_plan::PlanType, step_cursor::CursorType, persistent_context::PersistentContextType, step_wiring::WiringViewType, process::ProcessType, lifetime::LifetimeType) where {CarriedType, RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, ProcessType, LifetimeType}
    while true
        stepped_lc = @inline _step!(step_plan, step_cursor, LoopContext((@inline with_carried(persistent_context, carried)), runtime_context), step_wiring, Namespace{nothing}(), process, lifetime)
        stepped_persistent_context, stepped_runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
        carried = @inline next_carried(carried, stepped_persistent_context)
        @inline tick!(process)
        @inline inc!(process)
        (@inline _process_breakcondition(lifetime, process, stepped_persistent_context)) && return carried, stepped_runtime_context
        stepped_runtime_context isa RuntimeContextType || return _run_steps(carried, stepped_runtime_context, step_plan, step_cursor, persistent_context, step_wiring, process, lifetime)
        runtime_context = stepped_runtime_context
    end
end
