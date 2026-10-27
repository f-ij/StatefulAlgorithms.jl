#=
Interface of `ProcessSession`: what every session provides (its loop counter; its times, which by default it does not
keep), with defaults a session type can overload. The stop check is a hook: Hooks.jl (`process_breakcondition`). A process gives its session with
`getsession`, and forwards the counter to it (`loopidx(p)`).
=#

loopidx(s::ProcessSession) = s.loopidx
setloopidx!(s::ProcessSession, value) = (s.loopidx = value)
reset_loopidx!(s::ProcessSession) = setloopidx!(s, oneunit(loopidx(s)))

# `% Int`, not `Int(…)`: the loop reads this before every step (the lifetime's stop check), and a conversion that can
# throw makes LLVM store the counter to the session on every step, as the error could observe it.
loopint(s::ProcessSession) = loopidx(s) % Int

@inline inc!(s::ProcessSession) = s.loopidx += oneunit(s.loopidx)
@inline tick!(s::ProcessSession) = nothing

# Times: none by default; a session that keeps them overloads these (`InteractiveSession`).
@inline set_starttime!(::ProcessSession) = nothing
@inline set_endtime!(::ProcessSession) = nothing
@inline reset_times!(::ProcessSession) = nothing

"""Called by the loop before its first step: for an interactive session, records the start and the thread."""
@inline before_while(s::ProcessSession) = nothing

"""Whether the loop's exit is a pause (the run resumes later) rather than its end. Only an interactive session pauses."""
@inline _loop_ispaused(s::ProcessSession) = false

"""
    _loop_cursor(session, plan, resume)

The cursor the loop starts from: a new one, or for an interactive session that resumes, the one its pause kept.
"""
@inline _loop_cursor(s::ProcessSession, plan, ::Resuming) = loop_cursor(plan, Val(false))

"""Keep the cursor on a pause so the run resumes from it. Stored only on that exit, so the loop keeps it in registers."""
@inline _keep_loop_cursor!(::ProcessSession, cursor) = nothing

"""Clear the pause flag when a paused run resumes."""
@inline _clear_pause!(::ProcessSession) = nothing

export loopidx, loopint, inc!
