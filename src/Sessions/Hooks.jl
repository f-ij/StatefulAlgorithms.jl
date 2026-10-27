#=
Extendable API of process sessions: the check whether the run is interrupted (paused or closed).

Each function here has the default every session gets. Extended in:
- Sessions/HookExtensions.jl: `InteractiveSession` (its `shouldrun` flag);
- perf/cases.jl: an `InteractiveSession` with a `NoStopRepeat` lifetime (never interrupted, to time the loop without
  the check).

The logical stop check, a lifetime's own condition, is `lifetime_breakcondition` (Lifetimes/Hooks.jl).
=#

"""
    process_breakcondition(session) -> Bool

Whether the run of `session` is interrupted: its process was paused or closed from outside. Checked after every step
by the process loop (`Loops.jl`) and after every repeat inside a routine (`LoopAlgorithms/Step.jl`), so the run stops
there (a pause resumes after it). `false` by default: a session that cannot be paused or closed (`InlineSession`).
`InteractiveSession` adds a method that reads its `shouldrun` flag.

Repeats can run for a very long time, so an interruption must be seen between any two of them, not once per child.
Checked after the step, not before: a check before made LLVM select between the new and old values on the flag, which
put that read in every update's dependency chain (`17a1a33`).
"""
@inline process_breakcondition(session::S) where {S<:ProcessSession} = false
