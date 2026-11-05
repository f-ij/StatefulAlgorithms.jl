#=
The `Process` struct: a plan run on its own task, with its lifetime, state and runtime contexts, task, lock, listeners
and session. Two processes are equal when their ids are.
=#

export Process

mutable struct Process{F,C} <: InteractiveProcess{F,C}
    id::UUID
    algo::F
    # The lifetime of a run given none (`run(p; repeats/lifetime)` gives one); the run's own is `getlifetime(getsession(p))`.
    default_lifetime::Lifetime
    # The process's state, its user's handle (with the registry). Written only by `setcontext!`.
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
    # The plan's `UniqueKeyMap` (or `nothing`): `algo` and the contexts are kept without it, so the loop's types have no
    # uuid; `getcontext(p)` and `fetch(p)` put it back. Untyped, so the map's type is not in the `Process` type.
    keymap::Any
    # The context handed to the user (`getcontext(p)`): the state context with the map put back, built each time the
    # state context changes (`set_user_context!`). Untyped, as `keymap`.
    user_context::Any
end

Base.:(==)(p1::Process, p2::Process) = p1.id == p2.id
