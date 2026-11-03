#=
The `Process` struct: a plan run on its own task, with its lifetime, state and runtime contexts, task, lock, listeners
and session. Two processes are equal when their ids are.
=#

export Process

mutable struct Process{F,C} <: AbstractProcess
    id::UUID
    algo::F
    lifetime::Lifetime
    # The process's state when its type is not the one stored in the plan (`algo`), which is in the process's type;
    # `nothing` when the plan holds it. Written only by `_sync_state_context!`.
    state_context::Union{Nothing, ProcessContext}
    # A paused run's runtime context (its inputs and declared locals), kept by the run's end (`_finish_run!`) and read by
    # the resumed run or by `close`, which both clear it. `nothing` when no run is paused.
    runtime_context::Union{Nothing, ProcessContext}
    timeout::Float64
    task::Union{Nothing, Task}
    # To make sure other processes don't interfere
    lock::ReentrantLock
    lastresult::Any
    rls::RuntimeListeners
    # The current or last run (Processes/Process/Session.jl): what the loop gets instead of the process. The run's
    # counters, times, cursor and the flags `pause(p)` and `close(p)` set are its fields.
    session::InteractiveSession{C}
end

Base.:(==)(p1::Process, p2::Process) = p1.id == p2.id
