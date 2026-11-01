"""
    InlineSession

The session of a run that cannot be paused or closed: an `InlineProcess` (one session, made with the process and
reused by every `run(ip)`) and a plan run directly (`run(plan)`, one per run). Holds only the run's record: the loop
counter. The context and the plan are the loop's arguments (`run_session_loop`), as for a `Process`. No times
(nothing reads them, and the two clock calls would cost a short `run(ip)` more than its steps), no ticks and no stop
check (`process_breakcondition` is `false`).
"""
mutable struct InlineSession <: ProcessSession
    loopidx::UInt
end

InlineSession() = InlineSession(UInt(1))

# The counter starts at 1 for every run, set in the loop's own function: LLVM then knows its value and that its memory is
# written before the loop, so it keeps the counter in a register (written once, at the end).
@inline before_while(s::InlineSession) = reset_loopidx!(s)
