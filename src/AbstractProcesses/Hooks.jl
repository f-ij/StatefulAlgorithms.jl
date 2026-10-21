#=
Extendable API of processes: the check whether the process is interrupted (paused or closed).

Each function here has the default every process gets. Extended in:
- Process.jl: `Process` (its `shouldrun` flag);
- perf/cases.jl: a `Process` with a `NoStopRepeat` lifetime (never interrupted, to time the loop without the check).

The logical stop check, a lifetime's own condition, is `lifetime_breakcondition` (Lifetimes/Hooks.jl).
=#

"""
    process_breakcondition(process) -> Bool

Whether `process` is interrupted: paused or closed from outside. Checked after every step by the process loop
(`Loops.jl`) and after every repeat inside a routine (`LoopAlgorithms/Step.jl`), so the run stops there (a pause
resumes after it). `false` by default: a process that cannot be paused or closed (`InlineProcess`, the `LoopRunProcess`
of a hand-driven step). `Process` adds a method that reads its `shouldrun` flag.

Repeats can run for a very long time, so an interruption must be seen between any two of them, not once per child.
Checked after the step, not before: a check before made LLVM select between the new and old values on the flag, which
put that read in every update's dependency chain (`17a1a33`).
"""
@inline process_breakcondition(process::P) where {P<:AbstractProcess} = false
