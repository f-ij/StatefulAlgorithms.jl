"""
Running a composite algorithm allows for static unrolling and inlining of all sub-algorithms through 
    recursive calls
"""

"""
Step each scheduled child of a composite plan with explicit loop runtime.

The `process` and `lifetime` values are forwarded so nested loop algorithms can
run without storing those transient values in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(ca::CA, context::C, runtimecontext::RC, wiring::W, namespace::N, process::P, lifetime::LT) where {CA <: CompositeAlgorithm, C <: AbstractContext, RC <: ProcessContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(CA)
    interval_values = CA.parameters[2]
    child_namespace_tuple_type = CA.parameters[3]
    # Generate the same child-indexed execution as the old unrollreplace path,
    # but without the closure object on the hot non-generated loop path. The
    # schedule is known from the plan type, so `divides` specializes away for
    # interval-1 children.
    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(ca)))
    push!(exprs, :(local this_inc = @inline inc(ca)))

    for i in 1:algo_count
        interval_value = interval_values[i]
        interval_type = typeof(interval_value)
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        push!(exprs, quote
            if @inline divides(this_inc, $interval_type())
                local algo = @inline getfield(algos, $i)
                local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
                local child_namespace = $child_namespace_type()
                context, runtimecontext = @inline _step!(algo, context, runtimecontext, child_step_wiring, child_namespace, process, lifetime)
            end
        end)
    end

    push!(exprs, :(@inline inc!(ca)))
    push!(exprs, :(return context, runtimecontext))
    return Expr(:block, exprs...)
end

"""Step one lifetime-scheduled child inside a `Routine`."""
@inline function _subroutine_step!(
    context::C,
    runtimecontext::RC,
    func::F,
    r::R,
    process::P,
    lifetime::LT,
    idx::Int,
    subroutine_lifetime::SL,
    child_step_wiring::W,
    namespace::N,
) where {C,RC<:ProcessContext,F,R<:Routine,P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(r, idx)
    this_repeat_count = @inline routine_repeat_count(subroutine_lifetime)
    if resume_point <= this_repeat_count
        context, runtimecontext = @inline _step!(func, context, runtimecontext, child_step_wiring, namespace, process, lifetime)
        @inline tick!(process)

        next_idx = resume_point + 1
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, context, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, context, resume_point))
                @inline set_resume_point!(r, idx, next_idx)
            end
            return context, runtimecontext
        end

        for lidx in next_idx:this_repeat_count
            if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, context, lidx)
                if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, context, lidx))
                    @inline set_resume_point!(r, idx, lidx)
                end
                return context, runtimecontext
            end
            context, runtimecontext = @inline _step!(func, context, runtimecontext, child_step_wiring, namespace, process, lifetime)
            @inline tick!(process)
        end
    end
    return context, runtimecontext
end

"""
Step each child routine in sequence with explicit loop runtime.

Each child is run once at its resume point, then repeated until its declared
repeat count is reached or the lifetime stops.
"""
Base.@constprop :aggressive @inline @generated function _step!(r::R, context::C, runtimecontext::RC, wiring::W, namespace::N, process::P, lifetime::LT) where {R <: Routine, C <: AbstractContext, RC <: ProcessContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(R)
    repeat_values = R.parameters[2]
    child_namespace_tuple_type = R.parameters[3]

    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(r)))

    for i in 1:algo_count
        repeat_value = repeat_values[i]
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        push!(exprs, quote
            local func = @inline getfield(algos, $i)
            local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
            local child_namespace = $child_namespace_type()
            context, runtimecontext = @inline _subroutine_step!(context, runtimecontext, func, r, process, lifetime, $i, $repeat_value, child_step_wiring, child_namespace)
        end)
    end

    push!(exprs, :(return context, runtimecontext))
    return Expr(:block, exprs...)
end
