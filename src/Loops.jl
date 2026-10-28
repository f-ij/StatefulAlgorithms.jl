const start_finished = Ref(false)

"""
    finalizer!(func, persistent_context, runtime_context, session, lifetime)

Run cleanup and build the final result (`finalstep` gets `final_context`) while the run's runtime values are still
there. Returns the persistent context and the result; the runtime values end with the run.
"""
@inline function finalizer!(func::F, persistent_context::C, runtime_context::RC, session::S, lifetime::LT) where {F,C<:ProcessContext,RC<:ProcessContext,S<:ProcessSession,LT<:Lifetime}
    cleaned = @inline cleanup(func, LoopContext(persistent_context, runtime_context))
    return (@inline getpersistent(cleaned)), (@inline loop_final_result(func, (@inline final_context(cleaned)), getruntime(cleaned)))
end

"""
Build the runtime context for one run: its inputs (`_inputs`) and declared locals (`_declared_locals`). Returns
(`_captured_returns`, `_subcontext_returns`) are not in it: a step adds them where they are assigned and removes them
when their plan node ends (see `LoopContext`), so every step gets and returns a runtime context of this type.

The session and the lifetime are not in it: no step read them (they were in `_captured_returns` until 2026-10). Init still gets
the lifetime, for sizing (`InitContext`, `processsizehint!`). To give steps loop information again (step
index, total steps, elapsed time, a stop request), add narrow read-only values here rather than the session (`ProcessSession`),
which would tie step code to the session type; most of those uses belong in the plan (schedules, lifetimes) instead.
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

@inline function _loop_runtime_context(algo::F, inputs::NamedTuple, session::S, lifetime::LT, start_persistent_context::C, ::Resuming{false}) where {F,S<:ProcessSession,LT<:Lifetime,C<:ProcessContext}
    return @inline _initial_runtime_context(inputs, collect_tree_locals(algo))
end

@inline function _loop_runtime_context(algo::F, inputs::NamedTuple, session::S, lifetime::LT, start_persistent_context::C, ::Resuming{true}) where {F,S<:ProcessSession,LT<:Lifetime,C<:ProcessContext}
    runtime_inputs = @inline get_inputs(start_persistent_context)
    return @inline _initial_runtime_context(runtime_inputs, get_declared_locals(start_persistent_context))
end

"""Build the root wiring view for one loop execution."""
@inline _root_wiring_view(algo, step_plan) = PlanWiringView(getwiring(step_plan))

"""
    after_while(session, persistent_context, returnvalue) -> (persistent_context, returnvalue)

The loop's exit: records the end time (a session that keeps times) and returns the persistent context and the run's
result (on a pause, the paused context as both). Returned as the loop has them, without the plan's `UniqueKeyMap`; the
process that started the run commits them (`Process`: `_finish_run!`, which also puts the map back into what `fetch(p)` returns; `InlineProcess`:
`run_session_loop!`, which keeps the context on the session; `run(ip)` puts the map back into the result).
"""
@inline function after_while(session::S, persistent_context::C, returnvalue::R) where {S<:ProcessSession, C<:ProcessContext, R}
    @inline set_endtime!(session)
    return persistent_context, returnvalue
end

"""
    run_session_loop([loopfunc,] session, algo, context, lifetime, inputs, resume = Resuming{false}()) -> (persistent_context, result)

The loop as a call of its own, where a `Process` or a plan run directly (`run(plan)`) hands a run to it. Its
arguments are the session and the plan, context and lifetime without the plan's `UniqueKeyMap`, so it is compiled once
for every set of `Unique` handles while the process calling it is typed on the map. Also compiled as its own function,
so LLVM keeps the session's counters (`tickidx`) in registers.
"""
@noinline run_session_loop(loopfunc::LF, session::S, algo::A, context::C, lifetime::LT, inputs::I, resume::R = Resuming{false}()) where {LF, S<:ProcessSession, A, C, LT, I<:NamedTuple, R<:Resuming} =
    loopfunc(session, algo, context, lifetime, inputs, resume)
@inline run_session_loop(session::S, algo::A, context::C, lifetime::LT, inputs::I, resume::R = Resuming{false}()) where {S<:ProcessSession, A, C, LT, I<:NamedTuple, R<:Resuming} =
    run_session_loop(loop, session, algo, context, lifetime, inputs, resume)

"""
    run_session_loop!(session::InlineSession, algo, lifetime, inputs) -> result

The loop of an `InlineProcess` run on the context the session holds: it reads the context from the session and writes
the context after the run back to it. A call of its own, like `run_session_loop`: its arguments have no map in their
types, so its machine code is made once for every set of `Unique` handles, and `run(ip)`, which is compiled per set,
only calls it (1.1 ns per run). `run(ip; inlined = Val(true))` pastes the same body into `run(ip)` instead
(`run_session_loop_body!`): no call, but LLVM makes the loop's machine code again for every set of handles (5 ms for 2
children, 36 ms for 16). Its arguments are pointers and small values, so the call does not copy the context in or out.
The lifetime's `Var`s have their keys before the call (`resolve_var_keys`, in `run(ip)` or when the process was built).
"""
@noinline run_session_loop!(session::S, algo::A, lifetime::LT, inputs::I) where {C, S<:InlineSession{C}, A, LT, I<:NamedTuple} =
    @inline run_session_loop_body!(session, algo, lifetime, inputs)

# The body of `run_session_loop!`, inlined into its caller: into `run_session_loop!`, or into `run(ip)` for
# `inlined = Val(true)`.
@inline function run_session_loop_body!(session::S, algo::A, lifetime::LT, inputs::I) where {C, S<:InlineSession{C}, A, LT, I<:NamedTuple}
    # Here, not in the caller: LLVM then knows the counter starts at 1 and that its memory is written before the loop,
    # so it keeps the counter in a register (written once, at the end) and vectorizes steps the stop check cannot end.
    # In the caller it made the loop store the counter every step, 5x slower for light steps.
    reset_loopidx!(session)
    persistent_context, returnvalue = @inline loop(session, algo, session.context, lifetime, inputs, Resuming{false}())
    session.context = persistent_context
    return returnvalue
end

"""
Run a single function in a loop indefinitely.
"""
@inline loop(session::S, func::F, start_persistent_context::C, lt::LT, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {S<:ProcessSession, F, C, LT} =
    loop(session, func, start_persistent_context, lt, inputs, resume, sys_looptype)

@inline function loop(session::S, func::F, start_persistent_context::C, lifetime::LT, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {S<:ProcessSession,F<:AbstractLoopAlgorithm,C<:ProcessContext,LT<:IndefiniteLifetime,isresuming}
    @inline before_while(session)
    # The lifetime's `Var`s by key: the stop check before every step does not load the registry. A lifetime whose
    # `Var`s have their keys already (an `InlineProcess` gives them before the loop) stays as it is.
    lifetime = @inline resolve_var_keys(lifetime, start_persistent_context)

    step_plan = @inline getplan(func)
    step_wiring = @inline _root_wiring_view(func, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(session, step_plan, resume)
    persistent_context = @inline _loop_persistent_context(start_persistent_context, resume)
    runtime_context = @inline _loop_runtime_context(func, inputs, session, lifetime, start_persistent_context, resume)

    isresuming && @inline _clear_pause!(session)

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, LoopContext(persistent_context, runtime_context), step_wiring, Namespace{nothing}(), session, lifetime)
    carried, runtime_context = _run_steps(carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)
    persistent_context = @inline with_carried(persistent_context, carried)

    if @inline _loop_ispaused(session)
        @inline _keep_loop_cursor!(session, step_cursor)
        paused_context = @inline _paused_visible_context(persistent_context, runtime_context)
        return @inline after_while(session, paused_context, paused_context)
    end

    persistent_context, returnvalue = @inline finalizer!(func, persistent_context, runtime_context, session, lifetime)
    return @inline after_while(session, persistent_context, returnvalue)
end

"""
Run a single function in a loop for a given number of times.
"""
@inline loop(session::S, algo::F, start_persistent_context::C, r::R, inputs::NamedTuple = (;), resume::Resuming = Resuming{false}()) where {S<:ProcessSession, F, C, R <: RepeatLifetime} =
    loop(session, algo, start_persistent_context, r, inputs, resume, sys_looptype)

Base.@constprop :aggressive @inline function loop(session::S, algo::F, start_persistent_context::C, lifetime::R, inputs::NamedTuple, ::Resuming{isresuming}, ::NonGenerated) where {S<:ProcessSession,F<:AbstractLoopAlgorithm,C<:ProcessContext,R<:RepeatLifetime,isresuming}
    @DebugMode "Running the loop for $repeats times from thread $(Threads.threadid())"
    @assert isresolved(algo) "Algo must be resolved before running the loop. Got algo $(algo) which is not resolved."
    @inline before_while(session)
    # The lifetime's `Var`s by key: the stop check before every step does not load the registry. A lifetime whose
    # `Var`s have their keys already (an `InlineProcess` gives them before the loop) stays as it is.
    lifetime = @inline resolve_var_keys(lifetime, start_persistent_context)

    step_plan = @inline getplan(algo)
    step_wiring = @inline _root_wiring_view(algo, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(session, step_plan, resume)
    persistent_context = @inline _loop_persistent_context(start_persistent_context, resume)
    runtime_context = @inline _loop_runtime_context(algo, inputs, session, lifetime, start_persistent_context, resume)

    isresuming && @inline _clear_pause!(session)

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, LoopContext(persistent_context, runtime_context), step_wiring, Namespace{nothing}(), session, lifetime)
    carried, runtime_context = _repeat_steps((@inline loopidx(session)), carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)
    persistent_context = @inline with_carried(persistent_context, carried)

    if @inline _loop_ispaused(session)
        @inline _keep_loop_cursor!(session, step_cursor)
        paused_context = @inline _paused_visible_context(persistent_context, runtime_context)
        return @inline after_while(session, paused_context, paused_context)
    end

    persistent_context, returnvalue = @inline finalizer!(algo, persistent_context, runtime_context, session, lifetime)
    return @inline after_while(session, persistent_context, returnvalue)
end

"""
    _repeat_steps(i, carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)

Run steps `i` to `repeats(lifetime)` (until the process is paused or closed) and return the carried fields and the
runtime context after the last one. The steps run in a loop compiled for the runtime context's type; when a step
returns another type (a local declared without a type gets its first value, Locals.jl), the remaining steps continue in
a call compiled for that type, so the loop stays type-stable. Inlined into `loop` (as separate code, Routine plans ran
up to 1.9x slower); the call for a new type stays a call.
"""
@inline function _repeat_steps(i::IndexType, carried::CarriedType, runtime_context::RuntimeContextType, step_plan::PlanType, step_cursor::CursorType, persistent_context::PersistentContextType, step_wiring::WiringViewType, session::SessionType, lifetime::LifetimeType) where {IndexType<:Integer, CarriedType, RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, SessionType, LifetimeType}
    for j in i:(@inline repeats(lifetime))
        # Before the step: the lifetime's own stop condition (`Until`, ...), with the steps done; as a `while` loop's
        # condition, the same as for a routine child's repeats. It may read declared locals, so it sees both contexts.
        if @inline lifetime_breakcondition(lifetime, (@inline final_context(LoopContext((@inline with_carried(persistent_context, carried)), runtime_context))), (@inline loopint(session)) - 1)
            return carried, runtime_context
        end
        # The step's `LoopContext` is built from the pieces the loop carries, and taken apart again after it.
        stepped_lc = @inline _step!(step_plan, step_cursor, LoopContext((@inline with_carried(persistent_context, carried)), runtime_context), step_wiring, Namespace{nothing}(), session, lifetime)
        stepped_persistent_context, stepped_runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
        carried = @inline next_carried(carried, stepped_persistent_context)
        @inline tick!(session)
        @inline inc!(session)
        # After the step: a pause or close of the process.
        (@inline process_breakcondition(session)) && return carried, stepped_runtime_context
        stepped_runtime_context isa RuntimeContextType || return _repeat_steps(j + 1, carried, stepped_runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)
        runtime_context = stepped_runtime_context
    end
    return carried, runtime_context
end

"""
    _run_steps(carried, runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)

Run steps until the lifetime ends or the process is paused or closed and return the carried fields and the runtime context after the
last one; a runtime context of another type continues in a call compiled for that type, as in `_repeat_steps`.
"""
@inline function _run_steps(carried::CarriedType, runtime_context::RuntimeContextType, step_plan::PlanType, step_cursor::CursorType, persistent_context::PersistentContextType, step_wiring::WiringViewType, session::SessionType, lifetime::LifetimeType) where {CarriedType, RuntimeContextType, PlanType, CursorType, PersistentContextType, WiringViewType, SessionType, LifetimeType}
    while true
        # Before the step: the lifetime's own stop condition (`Until`, ...), with the steps done; as a `while` loop's
        # condition, the same as for a routine child's repeats. It may read declared locals, so it sees both contexts.
        if @inline lifetime_breakcondition(lifetime, (@inline final_context(LoopContext((@inline with_carried(persistent_context, carried)), runtime_context))), (@inline loopint(session)) - 1)
            return carried, runtime_context
        end
        # The step's `LoopContext` is built from the pieces the loop carries, and taken apart again after it.
        stepped_lc = @inline _step!(step_plan, step_cursor, LoopContext((@inline with_carried(persistent_context, carried)), runtime_context), step_wiring, Namespace{nothing}(), session, lifetime)
        stepped_persistent_context, stepped_runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
        carried = @inline next_carried(carried, stepped_persistent_context)
        @inline tick!(session)
        @inline inc!(session)
        # After the step: a pause or close of the process.
        (@inline process_breakcondition(session)) && return carried, stepped_runtime_context
        stepped_runtime_context isa RuntimeContextType || return _run_steps(carried, stepped_runtime_context, step_plan, step_cursor, persistent_context, step_wiring, session, lifetime)
        runtime_context = stepped_runtime_context
    end
end
