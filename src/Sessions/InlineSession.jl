"""
    InlineSession

The session of a run that cannot be paused or closed: an `InlineProcess` (one session, made with the process and
reused by every `run(ip)`, so a run allocates nothing) and a plan run directly (`run(plan)`, one per run). Holds the
loop counter and the start and end time; no ticks and no stop check (`process_breakcondition` is `false`).
"""
mutable struct InlineSession <: ProcessSession
    loopidx::UInt
    starttime::Union{Nothing, Float64, UInt64}
    endtime::Union{Nothing, Float64, UInt64}
end

InlineSession() = InlineSession(UInt(1), nothing, nothing)
