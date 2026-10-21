#=
Extendable API of loop algorithms: functions with a default that other types overload.

Each function here has the default every value gets. Extended in:
- `reset!`: Routines/HookExtensions.jl (`Routine`), FinalizedAlgorithm/HookExtensions.jl (`FinalizedAlgorithm`),
  Packaging/HookExtensions.jl (`Package`);
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
    reset!(x) -> x

Reset `x` before it runs again and return it: does nothing by default, for a `LoopAlgorithm` too. `reset!(::Process)`
calls it on the process's algorithm; a type that keeps counters between runs adds a method in a HookExtensions.jl next
to it (`Package` resets its interval counter, `Routine` resets its children).
"""
@inline reset!(x::T) where {T} = x
@inline reset!(la::LoopAlgorithm) = la

"""
    loop_final_result(algo, cleaned_context[, runtime_context]) -> result

The result a run of `algo` returns, given the context after cleanup (`final_context`): that context by default.
`FinalizedAlgorithm` adds a method (FinalizedAlgorithm/HookExtensions.jl) that returns its final function applied to it.
"""
@inline loop_final_result(algo::A, cleaned_context::C) where {A, C} = cleaned_context
@inline loop_final_result(algo::A, cleaned_context::C, runtime_context::RC) where {A, C, RC} = cleaned_context
