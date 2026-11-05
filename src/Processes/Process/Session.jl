"""
    InteractiveSession{C}

The session of a `Process` or `TimedProcess` run: a run the user can pause, resume and close while it runs. Made with
the process and kept on it after a run ends, so its counters and times stay readable; a resumed run goes on in the same
one, with the lifetime it started with.

- `shouldrun`, `paused`: set by the user (`pause(p)`, `close(p)`), read by the loop after every step and every routine
  repeat (`session_breakcondition`). Atomic, read without an ordering barrier.
- `loopidx`, `tickidx`: steps done and ticks (steps and routine repeats), written by the loop.
- `starttime`, `endtime`, `threadid`: when and where the run ran.
- `loop_cursor`: the cursor of a paused run (`C`, the plan's cursor type), so the run resumes where it stopped.
- `lifetime`: the run's lifetime, set by `run` (the run's `repeats`/`lifetime`, otherwise the process's
  `default_lifetime`) and by `reset!`, kept by a pause. Abstract: the loop gets it as an argument, so the loop is
  compiled for its concrete type (one dynamic call per run).
"""
mutable struct InteractiveSession{C} <: ProcessSession
    @atomic shouldrun::Bool
    @atomic paused::Bool
    loopidx::UInt
    tickidx::UInt
    starttime::Union{Nothing, Float64, UInt64}
    endtime::Union{Nothing, Float64, UInt64}
    loop_cursor::Union{Nothing, C}
    threadid::Int
    lifetime::Lifetime
end

# As a new process: not running (`shouldrun` off) and not started; `run(p)` sets both flags.
InteractiveSession{C}(lifetime::Lifetime) where {C} = InteractiveSession{C}(false, true, UInt(1), UInt(1), nothing, nothing, nothing, 0, lifetime)

@inline shouldrun(s::InteractiveSession) = @atomic :monotonic s.shouldrun

##########################################
########## Hook extensions ###############
##########################################

"""
    session_breakcondition(session::InteractiveSession) -> Bool

An interactive run is interrupted when its `shouldrun` flag is off (`pause(p)` or `close(p)`). Checked after every step
and after every routine repeat. Routine repeats can run for a very long time, so the check must stay per repeat:
checking only once per routine child (or every n repeats) would make a pause or close wait for the child's remaining
repeats and kill interactivity. The check costs a little per repeat and keeps the compiler from writing a routine's
repeats out one after another (perf/README.md shows the cost).
"""
@inline session_breakcondition(session::S) where {S<:InteractiveSession} = @inline !shouldrun(session)

@inline tick!(s::InteractiveSession) = (s.tickidx = s.tickidx + UInt(1))

@inline set_starttime!(s::InteractiveSession) = (s.starttime = time_ns())
@inline set_endtime!(s::InteractiveSession) = (s.endtime = time_ns())
@inline reset_times!(s::InteractiveSession) = (s.starttime = nothing; s.endtime = nothing)

@inline function before_while(s::InteractiveSession)
    s.threadid = Threads.threadid()
    @inline set_starttime!(s)
end

@inline loop_ispaused(s::InteractiveSession) = @atomic s.paused
@inline function starting_cursor(s::InteractiveSession{C}, plan, ::Resuming{IsResuming}) where {C, IsResuming}
    IsResuming && return s.loop_cursor::C
    return @inline loop_cursor(plan, Val(true))
end
@inline keep_loop_cursor!(s::InteractiveSession, cursor) = (s.loop_cursor = cursor; nothing)
@inline clear_pause!(s::InteractiveSession) = (@atomic s.paused = false; nothing)
