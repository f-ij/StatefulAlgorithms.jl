#=
Extendable API of processes: the check whether the process stops.

Each function here has the default every process gets. Extended in:
- Lifetimes/HookExtensions.jl: `Until`, `AtLeast`, `RepeatOrUntil`, `AtLeastAtMost` (their own stop condition);
- perf/cases.jl: `NoStopRepeat` (never stops, to time the loop without the check).
=#

"""
    process_breakcondition(lifetime, process, context) -> Bool

Whether the process stops. Checked by the process loop after every step (`Loops.jl`) and inside a routine after every
repeat of a child (`LoopAlgorithms/Step.jl`). By default (`Repeat`, `Indefinite`): when the process is paused or closed
(`!shouldrun(process)`). A lifetime with its own stop condition adds a method in Lifetimes/HookExtensions.jl that also
checks that condition, read from `context`.

Repeats can run for a very long time, so a pause or close of a `Process` must be seen between any two of them, not once
per child. See `shouldrun(::Process)`. A routine child's own stop condition is `routine_breakcondition`
(LoopAlgorithms/Routines/Hooks.jl).
"""
@inline process_breakcondition(lifetime::LT, process::P, context::C) where {LT<:Lifetime,P<:AbstractProcess,C} =
    @inline !shouldrun(process)
