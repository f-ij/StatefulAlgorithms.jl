"""
    InlineSession{C, A}

The session of a run that cannot be paused or closed: an `InlineProcess` (one session, made with the process and
reused by every `run(ip)`, so a run allocates nothing) and a plan run directly (`run(plan)`, one per run). Holds the
loop counter and, for an `InlineProcess`, what the loop runs: the process's context (`C`) and plan (`A`), both without
the plan's `UniqueKeyMap` (made so when the process hands them over, `set_session_context!`), so the loop is compiled
once for every set of `Unique` handles. `Nothing` for a session made without them. The loop reads the context from the
session and writes it back (`run_session_loop!`). No times
(nothing reads them, and the two clock calls would cost a short `run(ip)` more than its steps), no ticks and no stop check (`process_breakcondition` is `false`).
"""
mutable struct InlineSession{C, A} <: ProcessSession
    loopidx::UInt
    context::C
    const algo::A
end

InlineSession() = InlineSession{Nothing, Nothing}(UInt(1), nothing, nothing)
InlineSession(context::C, algo::A) where {C, A} = InlineSession{C, A}(UInt(1), context, algo)
