"""
Running a composite algorithm allows for static unrolling and inlining of all sub-algorithms through 
    recursive calls
"""

"""
Step each scheduled child of a composite plan with explicit loop runtime.

The `process` and `lifetime` values are forwarded so nested loop algorithms can
run without storing those transient values in the context.
"""
Base.@constprop :aggressive @inline @generated function _step!(ca::CA, cursor::S, lc::L, wiring::W, namespace::N, process::P, lifetime::LT) where {CA <: CompositeAlgorithm, S<:Union{CompositeLoopCursor,FirstTickCursor}, L <: LoopContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
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
    push!(exprs, :(local outer = lc))
    push!(exprs, :(lc = @inline enter_scope(lc, wiring)))

    for i in 1:algo_count
        schedule_value = schedule_values[i]
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        push!(exprs, quote
            if @inline should_run_schedule($schedule_value, this_inc, (@inline getpersistent(lc)))
                local algo = @inline getfield(algos, $i)
                local child_cursor = @inline child_loop_cursor(cursor, Val($i))
                local child_step_wiring = @inline child_wiring_view(wiring, Val($i))
                local child_namespace = $child_namespace_type()
                lc = @inline _step!(algo, child_cursor, lc, child_step_wiring, child_namespace, process, lifetime)
            end
        end)
    end

    push!(exprs, :(@inline inc!(cursor, ca)))
    push!(exprs, :(return @inline leave_scope(lc, outer)))
    return Expr(:block, exprs...)
end

"""
    _children_writes_expr(PlanType, repeat_values)

The body of `_writes` for a plan that steps its children in order (a composite, routine or threaded composite): the
union of its children's writes, each at its own position (cursor, wiring view, namespace), with the runtime context
type threaded from child to child as `_step!` threads the runtime context. A child that repeats (a routine child with
more than one repeat) uses the runtime type it settles on. `repeat_values` is `nothing` for a plan whose children run
once per step.
"""
function _children_writes_expr(PlanType::Type, repeat_values)
    child_namespace_tuple_type = PlanType.parameters[3]
    exprs = Any[:(local algos = @inline getalgos(plan)), :(local writes = Val(())), :(local runtime_context_type = RuntimeContextType)]
    for i in 1:numalgos(PlanType)
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        repeated = !isnothing(repeat_values) && !(repeat_values[i] isa Repeat && repeats(repeat_values[i]) == 1)
        settle = repeated ? :(runtime_context_type = @inline _runtime_context_type_over_repeats(child, child_cursor, persistent_context, runtime_context_type, child_wiring, child_namespace, process, lifetime)) : nothing
        push!(exprs, quote
            local child = @inline getfield(algos, $i)
            local child_cursor = @inline child_loop_cursor(cursor, Val($i))
            local child_wiring = @inline child_wiring_view(wiring, Val($i))
            local child_namespace = $child_namespace_type()
            $settle
            writes = @inline _union_writes(writes, (@inline _writes(child, child_cursor, persistent_context, runtime_context_type, child_wiring, child_namespace, process, lifetime)))
            runtime_context_type = @inline _runtime_context_type_after_node_step(child, child_cursor, persistent_context, runtime_context_type, child_wiring, child_namespace, process, lifetime)
        end)
    end
    push!(exprs, :(return writes))
    return Expr(:block, exprs...)
end

# The persistent fields a composite or routine writes (see src/Context/Carried/Writes.jl).
@inline @generated _writes(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:CompositeAlgorithm, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType, nothing)
@inline @generated _writes(plan::PlanType, cursor::CursorType, persistent_context::PersistentContextType, ::Type{RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType, process::ProcessType, lifetime::LifetimeType) where {PlanType<:Routine, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType} =
    _children_writes_expr(PlanType, PlanType.parameters[2])

"""Step one lifetime-scheduled child inside a `Routine`."""
@inline function _subroutine_step!(
    lc::L,
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
) where {L<:LoopContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    this_repeat_count = @inline routine_repeat_count(subroutine_lifetime)
    persistent_context = @inline getpersistent(lc)
    runtime_context = @inline getruntime(lc)
    if resume_point <= this_repeat_count
        # The repeats carry only the fields the child writes, as the loops do (see src/Context/Carried/Carry.jl); `context`
        # stays the routine's starting context.
        carried = @inline create_carried(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        stepped_lc = @inline _step!(func, func_cursor, (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context)), child_step_wiring, namespace, process, lifetime)
        stepped, runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
        carried = @inline next_carried(carried, stepped)
        @inline tick!(process)

        next_idx = resume_point + 1
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, stepped, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, stepped, resume_point))
                @inline set_resume_point!(routine_cursor, idx, next_idx)
            end
            return (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context))
        end

        for lidx in next_idx:this_repeat_count
            # Built fresh for the break checks: carrying `stepped` instead would make the whole context a loop variable.
            current = @inline with_carried(persistent_context, carried)
            if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, current, lidx)
                if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, current, lidx))
                    @inline set_resume_point!(routine_cursor, idx, lidx)
                end
                return @inline withcontexts(lc, current, runtime_context)
            end
            stepped_lc = @inline _step!(func, func_cursor, (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context)), child_step_wiring, namespace, process, lifetime)
            stepped, runtime_context = (@inline getpersistent(stepped_lc)), (@inline getruntime(stepped_lc))
            carried = @inline next_carried(carried, stepped)
            @inline tick!(process)
        end
        return (@inline withcontexts(lc, (@inline with_carried(persistent_context, carried)), runtime_context))
    end
    return lc
end

"""
Step a routine child that repeats once: the first repeat of `_subroutine_step!` without
the loop, so the child's `_step!` is emitted once instead of twice.
"""
@inline function _subroutine_step_once!(
    lc::L,
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
) where {L<:LoopContext,F,FS<:AbstractLoopCursor,R<:Routine,RS<:Union{DirectRoutineCursor,PausableRoutineCursor},P<:AbstractProcess,LT<:Lifetime,SL<:Lifetime,W,N<:Namespace}
    resume_point = @inline get_resume_point(routine_cursor, idx)
    if resume_point <= 1
        lc = @inline _step!(func, func_cursor, lc, child_step_wiring, namespace, process, lifetime)
        @inline tick!(process)
        persistent_context = @inline getpersistent(lc)
        if @inline routine_breakcondition(subroutine_lifetime, lifetime, process, persistent_context, resume_point)
            if !(@inline _routine_local_breakcondition(subroutine_lifetime, process, persistent_context, resume_point))
                @inline set_resume_point!(routine_cursor, idx, resume_point + 1)
            end
        end
    end
    return lc
end

"""
Step each child routine in sequence with explicit loop runtime.

Each child is run once at its resume point, then repeated until its declared
repeat count is reached or the lifetime stops.
"""
Base.@constprop :aggressive @inline @generated function _step!(r::R, cursor::S, lc::L, wiring::W, namespace::N, process::P, lifetime::LT) where {R <: Routine, S<:Union{DirectRoutineCursor,PausableRoutineCursor}, L <: LoopContext, W <: PlanWiringView, N <: Namespace, P <: AbstractProcess, LT <: Lifetime}
    algo_count = numalgos(R)
    repeat_values = R.parameters[2]
    child_namespace_tuple_type = R.parameters[3]

    exprs = Any[]
    sizehint!(exprs, algo_count + 4)
    push!(exprs, :(local algos = @inline getalgos(r)))
    push!(exprs, :(local outer = lc))
    push!(exprs, :(lc = @inline enter_scope(lc, wiring)))

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
            lc = @inline $substep(lc, func, func_cursor, r, cursor, process, lifetime, $i, $repeat_value, child_step_wiring, child_namespace)
        end)
    end

    push!(exprs, :(return @inline leave_scope(lc, outer)))
    return Expr(:block, exprs...)
end
