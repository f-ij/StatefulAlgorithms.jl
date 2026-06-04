"""
Generated process loop that inlines the step! expression when available.
"""
@inline @generated function loop(
    process::P,
    algo::F,
    context::C,
    lifetime::RL,
    inputs::I,
    ::Resuming{isresuming},
    ::Generated,
) where {P<:AbstractProcess, F<:AbstractLoopAlgorithm, C<:AbstractContext, RL<:RepeatLifetime, I<:NamedTuple, isresuming}
    return quote
        return @inline loop(process, algo, context, lifetime, inputs, Resuming{$isresuming}(), NonGenerated())
    end
end


# """
# Execute exactly one generated step for repeat-based lifetimes.

# This is the bootstrap pass that allows late-growing contexts to specialize the
# steady-state loop on the post-bootstrap context type.
# """
# @inline @generated function generated_firststep(process::AbstractProcess, algo::F, context::C, ::RL) where {F, C, RL <: RepeatLifetime}
#     algo_name = gensym(:algo)
#     step_expr = step!_expr(F, C, algo_name)

#     return quote
#         $(algo_name) = algo
#         $(step_expr)
#         @inline inc!(process)
#         @inline tick!(process)
#         return context
#     end
# end

# """
# Run the remaining repeat-based iterations after the bootstrap pass.
# """
# @inline @generated function generated_forloop(process::AbstractProcess, algo::F, context::C, r::RL, start_idx) where {F, C, RL <: RepeatLifetime}
#     algo_name = gensym(:algo)
#     step_expr = step!_expr(F, C, algo_name)

#     return quote
#         # reps = UInt(repeats(r))
#         # reps = repeats(r)

#         for i in start_idx:repeats(r)
#             $(algo_name) = algo
#             $(step_expr)
#             @inline inc!(process)
#             @inline tick!(process)
#             if @inline breakcondition(r, process, context)
#                 break
#             end
#         end
#         return context
#     end
# end

# @inline function generated_processloop(process::AbstractProcess, algo::F, context::C, r::RL) where {F, C, RL <: RepeatLifetime}
#     @inline before_while(process)
#     context = @inline generated_firststep(process, algo, context, r)
#     if @inline breakcondition(r, process, context)
#         return @inline after_while(process, algo, context)
#     end
#     context = @inline generated_forloop(process, algo, context, r, @inline loopidx(process))
#     return @inline after_while(process, algo, context)
# end



"""
Generated process loop that inlines the step! expression when available.
"""
@generated function loop(
    process::P,
    func::F,
    context::C,
    lifetime::LT,
    inputs::I,
    ::Resuming{isresuming},
    ::Generated,
) where {P<:AbstractProcess, F<:AbstractLoopAlgorithm, C<:AbstractContext, LT<:IndefiniteLifetime, I<:NamedTuple, isresuming}
    return quote
        return @inline loop(process, func, context, lifetime, inputs, Resuming{$isresuming}(), NonGenerated())
    end
end
