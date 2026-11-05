#=
Extendable API of process sessions: the check whether the run is interrupted (paused or closed), ticks, times, what
the loop does before its first step, and pausing (whether the loop's exit is a pause, the cursor it starts from and
keeps).

Each function here has the default every session gets. Extended, each in the hook-extensions section at the end of the
session's file, in:
- Processes/Process/Session.jl: `InteractiveSession` (all of them: its `shouldrun` and `paused` flags, ticks, times,
  the cursor of a paused run);
- Processes/InlineProcess/Session.jl: `InlineSession` (`before_while`: its counter starts at 1 for every run).

The logical stop check, a lifetime's own condition, is `lifetime_breakcondition` (Lifetimes/Hooks.jl).
=#

"""
    session_breakcondition(session) -> Bool

Whether the run of `session` is interrupted: its process was paused or closed from outside. Checked after every step
by the process loop (`Loops.jl`) and after every repeat inside a routine (`LoopAlgorithms/Step.jl`), so the run stops
there (a pause resumes after it). `false` by default: a session that cannot be paused or closed (`InlineSession`).
`InteractiveSession` adds a method that reads its `shouldrun` flag.

Repeats can run for a very long time, so an interruption must be seen between any two of them, not once per child.
Checked after the step, not before: a check before made LLVM select between the new and old values on the flag, which
put that read in every update's dependency chain (`17a1a33`).
"""
@inline session_breakcondition(session::S) where {S<:ProcessSession} = false

@inline tick!(s::ProcessSession) = nothing

# Times: none by default; a session that keeps them overloads these (`InteractiveSession`).
@inline set_starttime!(::ProcessSession) = nothing
@inline set_endtime!(::ProcessSession) = nothing
@inline reset_times!(::ProcessSession) = nothing

"""Called by the loop before its first step: for an interactive session, records the start and the thread."""
@inline before_while(s::ProcessSession) = nothing

"""Whether the loop's exit is a pause (the run resumes later) rather than its end. Only an interactive session pauses."""
@inline loop_ispaused(s::ProcessSession) = false

"""
    starting_cursor(session, plan, resume)

The cursor the loop starts from: a new one, or for an interactive session that resumes, the one its pause kept.
"""
@inline starting_cursor(s::ProcessSession, plan, ::Resuming) = loop_cursor(plan, Val(false))

"""Keep the cursor on a pause so the run resumes from it. Stored only on that exit, so the loop keeps it in registers."""
@inline keep_loop_cursor!(::ProcessSession, cursor) = nothing

"""Clear the pause flag when a paused run resumes."""
@inline clear_pause!(::ProcessSession) = nothing
