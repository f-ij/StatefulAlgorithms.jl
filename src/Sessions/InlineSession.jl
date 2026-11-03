"""
    InlineSession

The session of a run that cannot be paused or closed: an `InlineProcess` (one session, made with the process and
reused by every `run(ip)`, so a run allocates nothing) and a plan run directly (`run(plan)`, one per run). Holds only
the loop counter: no times (nothing reads them, and the two clock calls would cost a short `run(ip)` more than its
steps), no ticks and no stop check (`process_breakcondition` is `false`).
"""
mutable struct InlineSession <: ProcessSession
    loopidx::UInt
end

InlineSession() = InlineSession(UInt(1))
