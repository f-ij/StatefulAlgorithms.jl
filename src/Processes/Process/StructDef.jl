#=
The `Process` struct: a plan run on its own task, with its lifetime, state and runtime contexts, task, lock, listeners
and session. Two processes are equal when their keys in `processlist` (`list_ref`) are.
=#

export Process

mutable struct Process{F,C} <: InteractiveProcess{F,C}
    list_ref::UUID   # its key in `processlist` (not one of the plan's ids)
    # The plan; its registry holds the plan's `UniqueKeyMap`, the only place the process has the map. A run hands the plan
    # and the context to the loop without it (`prepare_for_loop`).
    algo::F
    # The lifetime of a run given none (`run(p; repeats/lifetime)` gives one); the run's own is `getlifetime(getsession(p))`.
    default_lifetime::Lifetime
    # The process's state, its user's handle (with the plan's registry, map included). Written only by `setcontext!`.
    state_context::ProcessContext
    # The `InitArgs`/`Override`/`Interactive` specs the context is set up from: the ones the process was built with, with
    # those of later `init!(p, ...)` calls merged in. A full `init!(p)` sets up from them again.
    specs::Tuple
    # A paused run's runtime context (its inputs and declared locals), kept by the run's end (`_store_run_contexts!`) and read by
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

Base.:(==)(p1::Process, p2::Process) = p1.list_ref == p2.list_ref
