#=
Extendable API of loop algorithms: functions with a default that other types overload.

Each function here has the default every value gets (`should_run_schedule` has none: every composite schedule entry
adds a method). Extended in:
- `loop_final_result`: FinalizedAlgorithm/HookExtensions.jl (`FinalizedAlgorithm`);
- the schedule-entry hooks `should_run_schedule`, `always_runs`, `compute_multiplier`: HookExtensions.jl next to this
  file (`Interval`, `RunIf`).
=#

"""
    should_run_schedule(entry, loopidx, context) -> Bool

Whether the composite child with schedule entry `entry` runs on tick `loopidx` of its composite. `context` is the
persistent context, read by an entry with a condition (`RunIf`). No default: each composite schedule entry adds a
method (HookExtensions.jl next to this file).
"""
function should_run_schedule end

"""
    always_runs(EntryType) -> Bool

Whether a composite child with a schedule entry of type `EntryType` runs on every tick, so its step needs no branch on
`should_run_schedule`: `false` by default. `Interval(1)` without an offset adds `true` (HookExtensions.jl next to this
file). Asked while the step is generated, so a method added after a plan type compiled is not seen by that type.
"""
@inline always_runs(::Type{E}) where {E} = false

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
