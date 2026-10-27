#=
Interface of `ProcessSession`: what every session provides (its loop counter and its times), with defaults a session
type can overload. The stop check is a hook: Hooks.jl (`process_breakcondition`). A process gives its session with
`getsession`, and forwards the counter to it (`loopidx(p)`).
=#

loopidx(s::ProcessSession) = s.loopidx
setloopidx!(s::ProcessSession, value) = (s.loopidx = value)
reset_loopidx!(s::ProcessSession) = setloopidx!(s, oneunit(loopidx(s)))

loopint(s::ProcessSession) = Int(loopidx(s))

@inline inc!(s::ProcessSession) = s.loopidx += oneunit(s.loopidx)
@inline tick!(s::ProcessSession) = nothing

@inline set_starttime!(s::ProcessSession) = (s.starttime = time_ns())
@inline set_endtime!(s::ProcessSession) = (s.endtime = time_ns())
@inline reset_times!(s::ProcessSession) = (s.starttime = nothing; s.endtime = nothing)

"""Called by the loop before its first step: records the start (and, for an interactive session, the thread)."""
@inline before_while(s::ProcessSession) = @inline set_starttime!(s)

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
