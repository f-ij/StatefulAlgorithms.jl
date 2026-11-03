"""
    InteractiveSession{C, LT}

The session of a `Process` run: a run on its own task that the user can pause, resume and close while it runs. Made
with the process and kept on it after a run ends, so its counters and times stay readable. A run whose lifetime has
another type gets a new session with the same counters (`create_session`); a resumed run goes on in the same one.

- `shouldrun`, `paused`: set by the user (`pause(p)`, `close(p)`), read by the loop after every step and every routine
  repeat (`process_breakcondition`). Atomic, read without an ordering barrier.
- `loopidx`, `tickidx`: steps done and ticks (steps and routine repeats), written by the loop.
- `starttime`, `endtime`, `threadid`: when and where the run ran.
- `loop_cursor`: the cursor of a paused run (`C`, the plan's cursor type), so the run resumes where it stopped.

`LT` is the run's lifetime type, so a hook can depend on it (perf/cases.jl: `NoStopRepeat`).
"""
mutable struct InteractiveSession{C, LT} <: ProcessSession
    @atomic shouldrun::Bool
    @atomic paused::Bool
    loopidx::UInt
    tickidx::UInt
    starttime::Union{Nothing, Float64, UInt64}
    endtime::Union{Nothing, Float64, UInt64}
    loop_cursor::Union{Nothing, C}
    threadid::Int
end

# As a new process: not running (`shouldrun` off) and not started; `run(p)` sets both flags.
InteractiveSession{C, LT}() where {C, LT} = InteractiveSession{C, LT}(false, true, UInt(1), UInt(1), nothing, nothing, nothing, 0)

@inline shouldrun(s::InteractiveSession) = @atomic :monotonic s.shouldrun
@inline tick!(s::InteractiveSession) = (s.tickidx = s.tickidx + UInt(1))

@inline set_starttime!(s::InteractiveSession) = (s.starttime = time_ns())
@inline set_endtime!(s::InteractiveSession) = (s.endtime = time_ns())
@inline reset_times!(s::InteractiveSession) = (s.starttime = nothing; s.endtime = nothing)

@inline function before_while(s::InteractiveSession)
    start_finished[] = true
    s.threadid = Threads.threadid()
    @inline set_starttime!(s)
end

@inline _loop_ispaused(s::InteractiveSession) = @atomic s.paused
@inline function _loop_cursor(s::InteractiveSession{C}, plan, ::Resuming{IsResuming}) where {C, IsResuming}
    IsResuming && return s.loop_cursor::C
    return @inline loop_cursor(plan, Val(true))
end
@inline _keep_loop_cursor!(s::InteractiveSession, cursor) = (s.loop_cursor = cursor; nothing)
@inline _clear_pause!(s::InteractiveSession) = (@atomic s.paused = false; nothing)
