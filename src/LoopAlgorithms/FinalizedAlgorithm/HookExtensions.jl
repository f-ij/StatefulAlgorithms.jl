#=
How a `FinalizedAlgorithm` extends the hooks of loop algorithms (LoopAlgorithms/Hooks.jl): the result of a run is its
final function applied to the context after cleanup.
=#

"""The result of a run: the final function applied to the context after cleanup."""
@inline function loop_final_result(fa::FA, cleaned_context::C) where {FA<:FinalizedAlgorithm, C}
    return finalfunction(fa)(cleaned_context)
end

"""
The result of a run: the final function applied to the context after cleanup, and to the run's runtime context when the
final function takes two arguments.
"""
@inline function loop_final_result(fa::FA, cleaned_context::C, runtime_context::RC) where {FA<:FinalizedAlgorithm, C, RC}
    final = finalfunction(fa)
    return applicable(final, cleaned_context, runtime_context) ? final(cleaned_context, runtime_context) : final(cleaned_context)
end
