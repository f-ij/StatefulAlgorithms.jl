"""
    InlineSession{C}

The session of a run that cannot be paused or closed: an `InlineProcess` (one session, made with the process and
reused by every `run(ip)`, so a run allocates nothing) and a plan run directly (`run(plan)`, one per run). Holds the
loop counter and, for an `InlineProcess`, its context (`C`; `Nothing` for a session made without one): the loop reads
it from the session and writes it back (`run_session_loop!`). No times
(nothing reads them, and the two clock calls would cost a short `run(ip)` more than its steps), no ticks and no stop check (`process_breakcondition` is `false`).
"""
mutable struct InlineSession{C} <: ProcessSession
    loopidx::UInt
    context::C
end

InlineSession() = InlineSession{Nothing}(UInt(1), nothing)
InlineSession(context::C) where {C} = InlineSession{C}(UInt(1), context)
