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

"""
    loop_context(algo, start_persistent_context, inputs, resume) -> LoopContext

The bundle a run starts from, built by the code that hands the run to the loop (`run(ip)`, a `Process` task, the
manager's inline run, `run(plan)`), so the loop gets it as an argument. `start_persistent_context` is the process's
context without the map. A new run gets the run's inputs and the plan's declared locals as its runtime context; a paused
run that resumes gets the inputs and declared locals kept in the paused context, which are cleared from the persistent
context.
"""
@inline loop_context(algo::F, start_persistent_context::C, inputs::NamedTuple, ::Resuming{false}) where {F,C<:ProcessContext} =
    LoopContext(start_persistent_context, (@inline _initial_runtime_context(inputs, collect_tree_locals(algo))))
@inline loop_context(algo::F, start_persistent_context::C, ::NamedTuple, ::Resuming{true}) where {F,C<:ProcessContext} =
    LoopContext((@inline _paused_state_context(start_persistent_context)),
                (@inline _initial_runtime_context((@inline get_inputs(start_persistent_context)), get_declared_locals(start_persistent_context))))

"""Build the root wiring view for one loop execution."""
@inline _root_wiring_view(algo, step_plan) = PlanWiringView(getwiring(step_plan))

"""
    after_while(session, persistent_context, returnvalue) -> (persistent_context, returnvalue)

The loop's exit: records the end time (a session that keeps times) and returns the persistent context and the run's
result (on a pause, the paused context as both). Returned as the loop has them, without the plan's `UniqueKeyMap`; the
process that started the run commits them (`Process`: `_finish_run!`, which gives what it keeps and `fetch(p)` the plan's
registry back; `InlineProcess`: `run(ip)`, which stores the context on the process and gives the result the plan's
registry).
"""
@inline function after_while(session::S, persistent_context::C, returnvalue::R) where {S<:ProcessSession, C<:ProcessContext, R}
    @inline set_endtime!(session)
    return persistent_context, returnvalue
end

"""
    run_session_loop([loopfunc,] session, algo, loop_context, lifetime, resume = Resuming{false}()) -> (persistent_context, result)

The loop as a call of its own, where a `Process`, an `InlineProcess` or a plan run directly (`run(plan)`) hands a run to it. Its
arguments are the session, the plan, the `LoopContext` the run starts from (`loop_context`) and the lifetime, without the plan's `UniqueKeyMap`, so it is compiled once
for every set of `Unique` handles while the process calling it has the map in its type (in its plan's registry). Also compiled as its own function,
so LLVM keeps the session's counters (`tickidx`) in registers.
"""
@noinline run_session_loop(loopfunc::LF, session::S, algo::A, lc::LC, lifetime::LT, resume::R = Resuming{false}()) where {LF, S<:ProcessSession, A, LC<:LoopContext, LT, R<:Resuming} =
    loopfunc(session, algo, lc, lifetime, resume)
@inline run_session_loop(session::S, algo::A, lc::LC, lifetime::LT, resume::R = Resuming{false}()) where {S<:ProcessSession, A, LC<:LoopContext, LT, R<:Resuming} =
    run_session_loop(loop, session, algo, lc, lifetime, resume)

"""
Run a single function in a loop indefinitely.
"""
@inline loop(session::S, func::F, lc::LC, lt::LT, resume::Resuming = Resuming{false}()) where {S<:ProcessSession, F, LC<:LoopContext, LT} =
    loop(session, func, lc, lt, resume, sys_looptype)

@inline function loop(session::S, func::F, lc::LC, lifetime::LT, ::Resuming{isresuming}, ::NonGenerated) where {S<:ProcessSession,F<:AbstractLoopAlgorithm,LC<:LoopContext,LT<:IndefiniteLifetime,isresuming}
    @inline before_while(session)
    # The lifetime's `Var`s by key: the stop check before every step does not load the registry. A lifetime whose
    # `Var`s have their keys already (an `InlineProcess` gives them before the loop) stays as it is.
    lifetime = @inline resolve_var_keys(lifetime, (@inline getpersistent(lc)))

    step_plan = @inline getplan(func)
    step_wiring = @inline _root_wiring_view(func, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(session, step_plan, resume)
    persistent_context = @inline getpersistent(lc)
    runtime_context = @inline getruntime(lc)

    isresuming && @inline _clear_pause!(session)

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, lc, step_wiring, Namespace{nothing}(), session, lifetime)
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
@inline loop(session::S, algo::F, lc::LC, r::R, resume::Resuming = Resuming{false}()) where {S<:ProcessSession, F, LC<:LoopContext, R <: RepeatLifetime} =
    loop(session, algo, lc, r, resume, sys_looptype)

Base.@constprop :aggressive @inline function loop(session::S, algo::F, lc::LC, lifetime::R, ::Resuming{isresuming}, ::NonGenerated) where {S<:ProcessSession,F<:AbstractLoopAlgorithm,LC<:LoopContext,R<:RepeatLifetime,isresuming}
    @DebugMode "Running the loop for $repeats times from thread $(Threads.threadid())"
    @assert isresolved(algo) "Algo must be resolved before running the loop. Got algo $(algo) which is not resolved."
    @inline before_while(session)
    # The lifetime's `Var`s by key: the stop check before every step does not load the registry. A lifetime whose
    # `Var`s have their keys already (an `InlineProcess` gives them before the loop) stays as it is.
    lifetime = @inline resolve_var_keys(lifetime, (@inline getpersistent(lc)))

    step_plan = @inline getplan(algo)
    step_wiring = @inline _root_wiring_view(algo, step_plan)
    resume = Resuming{isresuming}()
    step_cursor = @inline _loop_cursor(session, step_plan, resume)
    persistent_context = @inline getpersistent(lc)
    runtime_context = @inline getruntime(lc)

    isresuming && @inline _clear_pause!(session)

    # Carry only the fields the steps write, not the whole context: fields left unchanged would otherwise be copied every
    # step (see src/Context/Carried/Carry.jl).
    carried = @inline create_carried(step_plan, step_cursor, lc, step_wiring, Namespace{nothing}(), session, lifetime)
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
