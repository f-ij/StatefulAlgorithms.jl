#=
Extendable API of loop algorithms: functions with a default that other types overload.
=#

"""
    iscomposite(x) -> Bool

Whether `x` (a value or a type) is a composite plan, which steps all its children in order each step: `false` by
default. A wrapper of a loop algorithm adds a method that asks what it wraps (`FinalizedAlgorithm`).
"""
@inline iscomposite(x::T) where {T} = false

"""
    reset!(x) -> x

Reset `x` before it runs again and return it: does nothing by default. `reset!(::Process)` calls it on the process's
algorithm; a type that keeps counters between runs adds a method (`Package` resets its interval counter).
"""
@inline reset!(x::T) where {T} = x

"""
    _loop_final_result(algo, cleaned_context[, runtime_context]) -> result

The result a run of `algo` returns, given the context after cleanup (`final_context`): that context by default.
`FinalizedAlgorithm` adds a method that returns its final function applied to it.
"""
@inline _loop_final_result(algo::A, cleaned_context::C) where {A, C} = cleaned_context
@inline _loop_final_result(algo::A, cleaned_context::C, runtime_context::RC) where {A, C, RC} = cleaned_context
