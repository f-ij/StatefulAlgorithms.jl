#=
Extendable API of loop algorithms: functions with a default that other types overload.

Each function here has the default every value gets. Extended in:
- `loop_final_result`: FinalizedAlgorithm/HookExtensions.jl (`FinalizedAlgorithm`);
- `iscomposite`: a trait more than a hook (TODO.md, "Hooks" 3), so its methods stay with the types: Accessors.jl
  (plans), FinalizedAlgorithm/FinalizedAlgorithm.jl, Threaded/CompositeAlgorithms.jl.
=#

"""
    iscomposite(x) -> Bool

Whether `x` (a value or a type) is a composite plan, which steps all its children in order each step: `false` by
default. A wrapper of a loop algorithm adds a method that asks what it wraps (`FinalizedAlgorithm`).
"""
@inline iscomposite(x::T) where {T} = false

"""
    loop_final_result(algo, cleaned_context[, runtime_context]) -> result

The result a run of `algo` returns, given the context after cleanup (`final_context`): that context by default.
`FinalizedAlgorithm` adds a method (FinalizedAlgorithm/HookExtensions.jl) that returns its final function applied to it.
"""
@inline loop_final_result(algo::A, cleaned_context::C) where {A, C} = cleaned_context
@inline loop_final_result(algo::A, cleaned_context::C, runtime_context::RC) where {A, C, RC} = cleaned_context
