"""
Running a composite algorithm allows for static unrolling and inlining of all sub-algorithms through 
    recursive calls
"""

"""
Step each scheduled child of a composite plan with explicit loop runtime.

The `process` and `lifetime` values are forwarded so nested loop algorithms can
run without storing those transient values in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(ca::CA, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N, process::P, lifetime::LT) where {CA <: CompositeAlgorithm, S<:Union{CompositeLoopCursor,FirstTickCursor}, C <: AbstractContext, RC <: ProcessContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(CA)
    schedule_values = CA.parameters[2]
    child_namespace_tuple_type = CA.parameters[3]
    # Generate the same child-indexed execution as the old unrollreplace path,
    # but without the closure object on the hot non-generated loop path. The
    # schedule is known from the plan type, so `divides` specializes away for
    # interval-1 children.
    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(ca)))
    push!(exprs, :(local this_inc = @inline inc(cursor)))

    for i in 1:algo_count
        schedule_value = schedule_values[i]
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        push!(exprs, quote
            if @inline should_run_schedule($schedule_value, this_inc, context)
                local algo = @inline getfield(algos, $i)
                local child_cursor = @inline child_loop_cursor(cursor, Val($i))
                local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
                local child_namespace = $child_namespace_type()
                stepped, runtimecontext = @inline _step!(algo, child_cursor, (@inline child_context(context)), runtimecontext, child_step_wiring, child_namespace, process, lifetime)
                context = @inline with_child_log(context, stepped)
            end
        end)
    end

    push!(exprs, :(@inline inc!(cursor, ca)))
    push!(exprs, :(return context, runtimecontext))
    return Expr(:block, exprs...)
end

"""Step one lifetime-scheduled child inside a `Routine`."""
@inline function _subroutine_step!(
    context::C,
    runtimecontext::RC,
    func::F,
    func_cursor::FS,
    r::R,
    routine_cursor::RS,
    process::P,
    lifetime::LT,
    idx::Int,
    subroutine_lifetime::SL,
    child_step_wiring::W,
    namespace::N,
) where {C,RC<:ProcessContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    this_repeat_count = @inline routine_repeat_count(subroutine_lifetime)
    if resume_point <= this_repeat_count
        # The repeats carry only the fields the child writes (Carry.jl); `context` stays the routine's starting context.
        written = @inline _written_fields(func, func_cursor, context, runtimecontext, child_step_wiring, namespace, process, lifetime)
        carried = @inline loop_carry(context, written)
        stepped, runtimecontext = @inline _step!(func, func_cursor, (@inline step_context(context, carried, written)), runtimecontext, child_step_wiring, namespace, process, lifetime)
        carried = @inline next_carry(stepped, written)
        @inline tick!(process)

        next_idx = resume_point + 1
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, stepped, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, stepped, resume_point))
                @inline set_resume_point!(routine_cursor, idx, next_idx)
            end
            return (@inline carried_context(context, carried, written)), runtimecontext
        end

        for lidx in next_idx:this_repeat_count
            current = @inline carried_context(context, carried, written)
            if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, current, lidx)
                if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, current, lidx))
                    @inline set_resume_point!(routine_cursor, idx, lidx)
                end
                return current, runtimecontext
            end
            stepped, runtimecontext = @inline _step!(func, func_cursor, (@inline step_context(context, carried, written)), runtimecontext, child_step_wiring, namespace, process, lifetime)
            carried = @inline next_carry(stepped, written)
            @inline tick!(process)
        end
        return (@inline carried_context(context, carried, written)), runtimecontext
    end
    return context, runtimecontext
end

"""
Step a routine child that repeats once: the first repeat of `_subroutine_step!` without
the loop, so the child's `_step!` is emitted once instead of twice.
"""
@inline function _subroutine_step_once!(
    context::C,
    runtimecontext::RC,
    func::F,
    func_cursor::FS,
    r::R,
    routine_cursor::RS,
    process::P,
    lifetime::LT,
    idx::Int,
    subroutine_lifetime::SL,
    child_step_wiring::W,
    namespace::N,
) where {C,RC<:ProcessContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    if resume_point <= 1
        context, runtimecontext = @inline _step!(func, func_cursor, context, runtimecontext, child_step_wiring, namespace, process, lifetime)
        @inline tick!(process)
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, context, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, context, resume_point))
                @inline set_resume_point!(routine_cursor, idx, resume_point + 1)
            end
        end
    end
    return context, runtimecontext
end

"""
Step each child routine in sequence with explicit loop runtime.

Each child is run once at its resume point, then repeated until its declared
repeat count is reached or the lifetime stops.
"""
Base.@constprop :aggressive @inline @generated function _step!(r::R, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N, process::P, lifetime::LT) where {R <: Routine, S<:Union{DirectRoutineCursor,PausableRoutineCursor}, C <: AbstractContext, RC <: ProcessContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(R)
    repeat_values = R.parameters[2]
    child_namespace_tuple_type = R.parameters[3]

    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(r)))

    for i in 1:algo_count
        repeat_value = repeat_values[i]
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        # Repeat counts are part of the plan type: a single-repeat child needs no loop.
        substep = repeat_value isa Repeat && repeats(repeat_value) == 1 ? :_subroutine_step_once! : :_subroutine_step!
        push!(exprs, quote
            local func = @inline getfield(algos, $i)
            local func_cursor = @inline child_loop_cursor(cursor, Val($i))
            local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
            local child_namespace = $child_namespace_type()
            stepped, runtimecontext = @inline $substep((@inline child_context(context)), runtimecontext, func, func_cursor, r, cursor, process, lifetime, $i, $repeat_value, child_step_wiring, child_namespace)
            context = @inline with_child_log(context, stepped)
        end)
    end

    push!(exprs, :(return context, runtimecontext))
    return Expr(:block, exprs...)
end
