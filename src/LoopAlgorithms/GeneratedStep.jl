"""
Generated expression form for a resolved `LoopAlgorithm`.

Generated process loops receive the resolved wrapper at the root. Inline the
stored plan directly so generated code does not call the old no-runtime
`step!` entry point.
"""
function step!_expr(::Type{LA}, context::Type{C}, name::Symbol, wiringname::Symbol) where {Plan, LA<:LoopAlgorithm{Plan}, C<:AbstractContext}
    plan_name = gensym(:plan)
    return quote
        local $plan_name = @inline getplan($name)
        $(step!_expr(Plan, C, plan_name, wiringname))
    end
end

"""
Generated expression form for a finalized root loop algorithm.

Finalization affects the result after cleanup, not the loop step itself, so the
generated step expression delegates to the wrapped algorithm.
"""
function step!_expr(::Type{FA}, context::Type{C}, name::Symbol, wiringname::Symbol) where {LA, FA<:FinalizedAlgorithm{LA}, C<:AbstractContext}
    plan_type = getplan(FA)
    plan_name = gensym(:plan)
    return quote
        local $plan_name = @inline getplan($name)
        $(step!_expr(plan_type, C, plan_name, wiringname))
    end
end

"""
Generated expression form of the composite step! with a caller-provided name binding.
"""
function step!_expr(ca::Type{CA}, context::Type{C}, name::Symbol, wiringname::Symbol) where {CA<:CompositeAlgorithm, C<:AbstractContext}
    # This method does not execute the algorithm directly. Instead, it *builds an Expr*
    # representing the body of a `step!` method specialized to:
    # - the CompositeAlgorithm type `ca`
    # - the AbstractContext subtype `C`
    #
    # Each `push!(exprs, ...)` adds (roughly) one "line" to the generated function body.
    # `ca.parameters[1]` is the function-tuple type that stores the child algorithms.
   
    exprs = Any[]
    algo_count = numalgos(ca)
    interval_values = ca.parameters[2]
    child_namespace_tuple_type = ca.parameters[3]
    child_wiring_type = ca.parameters[4].parameters[2]
    sizehint!(exprs, algo_count + 4)
    # Generated line: `this_inc = inc(name)` (read the composite's step counter once).
    push!(exprs, :(local this_inc = @inline inc($name)))
    for i in 1:algo_count
        interval_value = interval_values[i]
        interval_type = typeof(interval_value)
        child_step_wiring_type = fieldtype(child_wiring_type, i)
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        local_name = gensym(:algo)
        local_wiring = gensym(:child_step_wiring)
        local_namespace = gensym(:child_namespace)
        push!(exprs, quote
            # Only run this child every `interval` composite steps.
            if @inline divides(this_inc, $interval_type())
                local $local_name = @inline getalgo($name, $i)
                local $local_wiring = $child_step_wiring_type()
                local $local_namespace = $child_namespace_type()
                context = @inline _step!($local_name, context, $local_wiring, $local_namespace, process, lifetime)
            end
        end)
    end
    # Generated line: `inc!(name)` (advance composite counter after running children).
    push!(exprs, :(@inline inc!($name)))
    # push!(exprs, :(GC.safepoint()))
    # Generated line: `context` (ensure the generated function returns the runtime context).
    push!(exprs, :(context))
    return Expr(:block, exprs...)
end

"""
Generated expression form of the routine step! with a caller-provided name binding.
"""
function step!_expr(routine::Type{R}, context::Type{C}, name::Symbol, wiringname::Symbol) where {R<:Routine, C<:AbstractContext}
    # Builds an Expr representing the body of `step!` for a Routine:
    # each child algorithm runs `reps[i]` times before moving to the next.

    exprs = Any[]
    algo_count = numalgos(routine)
    repeat_values = routine.parameters[2]
    child_namespace_tuple_type = routine.parameters[3]
    child_wiring_type = routine.parameters[5].parameters[2]
    sizehint!(exprs, algo_count + 3)

    for i in 1:algo_count
        this_lifetime = repeat_values[i]
        this_lifetime_type = typeof(this_lifetime)
        child_step_wiring_type = fieldtype(child_wiring_type, i)
        child_namespace_type = fieldtype(child_namespace_tuple_type, i)
        local_name = gensym(:algo)
        local_wiring = gensym(:child_step_wiring)
        local_namespace = gensym(:child_namespace)
        

        # Generated line: `local algoᵢ = getalgo(name, i)` (bind child algorithm instance).
        this_lifetime_type <: Lifetime || error("Routine schedules must be `Lifetime` values after construction. Got $(this_lifetime_type).")
        push!(exprs, quote
            local $local_name = @inline getalgo($name, $i)
            local $local_wiring = $child_step_wiring_type()
            local $local_namespace = $child_namespace_type()
            local _subroutine_lifetime = $this_lifetime
            local _routine_repeat_count = @inline routine_repeat_count(_subroutine_lifetime)
            if resume_idx($name, $i) <= _routine_repeat_count
                context = @inline _step!($local_name, context, $local_wiring, $local_namespace, process, lifetime)
                @inline tick!(process)

                local _routine_next_idx = resume_idx($name, $i) + 1
                local _routine_resume_point = resume_idx($name, $i)
                if @inline routine_breakcondition(_subroutine_lifetime, lifetime, process, context, _routine_resume_point)
                    if !(@inline _routine_local_breakcondition(_subroutine_lifetime, process, context, _routine_resume_point))
                        set_resume_point!($name, $i, _routine_next_idx)
                    end
                    return context
                end

                for lidx in _routine_next_idx:_routine_repeat_count
                    if @inline routine_breakcondition(_subroutine_lifetime, lifetime, process, context, lidx)
                        if !(@inline _routine_local_breakcondition(_subroutine_lifetime, process, context, lidx))
                            set_resume_point!($name, $i, lidx)
                        end
                        return context
                    end
                    context = @inline _step!($local_name, context, $local_wiring, $local_namespace, process, lifetime)
                    @inline tick!(process)
                end
            end
        end)
    end
    # Generated line: `context` (ensure the generated function returns the runtime context).
    push!(exprs, :(context))
    return Expr(:block, exprs...)
end


"""
Fallback expression form for non-CLA algorithms.
"""
function step!_expr(::Type{T}, ::Type{C}, funcname::Symbol, wiringname::Symbol) where {T, C<:AbstractContext}
    # Generated single line:
    #   context = _step!(funcname, context, wiring, namespace, process, lifetime)
    # This keeps generated loops aligned with the normal runtime route/share
    # semantics for algorithms that do not provide a custom expression form.
    return :(context = @inline _step!($funcname, context, $wiringname, Namespace{nothing}(), process, lifetime))
end
