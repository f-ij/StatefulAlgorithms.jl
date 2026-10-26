#=
Extendable API of loop algorithms: functions with a default that other types overload.

Each function here has the default every value gets. Extended in:
- `loop_final_result`: FinalizedAlgorithm/HookExtensions.jl (`FinalizedAlgorithm`);
- `compute_multiplier`: HookExtensions.jl next to this file (`Interval`, `RunIf`);
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
    compute_multiplier(entry) -> Float64

How often a child runs per run of its plan, from its schedule entry `entry` (one element of `getschedule(plan)`). By
default the entry's repeat count, `repeats(entry)`: a routine child's lifetime (`Repeat(n)` gives `n`, `RepeatOnce` 1,
a lifetime without a count `Inf`). `Interval` and `RunIf` add a method (HookExtensions.jl next to this file): `1/n` for
interval `n`. Both the registry setup from values and the generated one call it (`multipliers`, Interface.jl).
"""
@inline compute_multiplier(entry::E) where {E} = Float64(repeats(entry))

"""
    loop_final_result(algo, cleaned_context[, runtime_context]) -> result

The result a run of `algo` returns, given the context after cleanup (`final_context`): that context by default.
`FinalizedAlgorithm` adds a method (FinalizedAlgorithm/HookExtensions.jl) that returns its final function applied to it.
"""
@inline loop_final_result(algo::A, cleaned_context::C) where {A, C} = cleaned_context
@inline loop_final_result(algo::A, cleaned_context::C, runtime_context::RC) where {A, C, RC} = cleaned_context
