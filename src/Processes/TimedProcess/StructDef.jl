#=
The `TimedProcess` struct: a plan run one step per `Timer` tick, with its lifetime, state and runtime contexts, timer,
lock and session.
=#

export TimedProcess

mutable struct TimedProcess{F,C} <: InteractiveProcess{F,C}
    algo::F
    # As in `Process`: the lifetime of a run given none; the run's own is `getlifetime(getsession(tp))`.
    default_lifetime::Lifetime
    # As in `Process`: the process's state; written only by `setcontext!`.
    state_context::ProcessContext
    # As in `Process`: the specs the context is set up from (construction, merged with later `init!` calls).
    specs::Tuple
    # The run's runtime context (its inputs and declared locals) between two ticks and while paused, read and written by
    # every tick. `nothing` when no run is going on.
    runtime_context::Union{Nothing, ProcessContext}
    # Seconds between two ticks.
    const interval::Float64
    # Runs a tick every `interval` seconds; `nothing` while not running.
    timer::Union{Nothing, Timer}
    # Held by a tick, so `pause` and `close` wait for a tick that is going on.
    const lock::ReentrantLock
    lastresult::Any
    # The run's counters, times, cursor and the `shouldrun` flag a tick's routines check (Processes/Process/Session.jl).
    session::InteractiveSession{C}
end
