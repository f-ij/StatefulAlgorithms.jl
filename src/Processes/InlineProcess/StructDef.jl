#=
The `InlineProcess` struct: a plan run in the caller's task, with its context, lifetime and its one session.
=#

export InlineProcess

"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart. A run runs in the caller's task:
running on a task of its own is what `Process` is for.
"""
mutable struct InlineProcess{TD,ContextType, Lt, S<:Tuple} <: AbstractProcess
    const id::UUID
    const algo::TD
    # The process's context: the loop gets it as an argument (`run_session_loop`) and gives the new one back, which
    # `run(ip)` stores here.
    context::ContextType
    # The `InitArgs`/`Override`/`Interactive` specs the process was built with (resolved, merged per target), the ones
    # `reset!(ip)` and a full `init(ip)` set up from. Typed and fixed, so code reading them stays type stable:
    # `init(ip, specs...)` returns a new process with the merged specs.
    const specs::S
    # The lifetime of a run given none (`run(ip; repeats/lifetime)` gives one for that run).
    default_lifetime::Lt
    # The run's counter, one session for every run (Processes/InlineProcess/Session.jl): what the loop gets instead of the
    # process.
    const session::InlineSession
end
