#=
The `InlineProcess` struct: a plan run in the caller's task, with its context, lifetime and its one session.
=#

export InlineProcess

"""
A fully typed process that is meant for inlining into other Functions
Mainly used to compose algorithms in tight loops, plugging into the ProcessLoopAlgorithm system

This doesn't provide the multitasking features of Process, but is faster to restart. A run runs in the caller's task,
or on a task with `run(ip; async = Val(true))`. It cannot be paused or closed, so it never takes an `Indefinite`
lifetime.
"""
mutable struct InlineProcess{TD,ContextType, Lt, S<:Tuple, A} <: AbstractProcess
    const id::UUID
    # The plan; its registry holds the plan's `UniqueKeyMap`, so the type has it and `run(ip)` compiles once per set of
    # `Unique` handles. A run hands plan and context to the loop without it (`prepare_for_loop`).
    const algo::TD
    # The process's context, with the plan's registry (map included): the loop gets it without its registry
    # (`drop_registry`) as an argument (`run_session_loop`) and gives the new values back, which `run(ip)` stores here.
    context::ContextType
    # The `InitArgs`/`Override`/`Interactive` specs the process was built with (resolved, merged per target), the ones
    # `reset(ip)` and a full `init(ip)` set up from. Typed and fixed, so code reading them stays type stable:
    # `init(ip, specs...)` and `reset(ip, specs...)` return a new process with the merged specs.
    const specs::S
    # The lifetime of a run given none (`run(ip; repeats/lifetime)` gives one for that run).
    default_lifetime::Lt
    # The run's counter, one session for every run (Processes/InlineProcess/Session.jl): what the loop gets instead of the
    # process.
    const session::InlineSession
    # `algo` without the plan's `UniqueKeyMap` (`strip_keymap`), made once with the process: the plan every run hands to
    # the loop (`prepare_for_loop`), so a run does not rebuild it. Not a map: the map is only in `algo`'s registry.
    const loop_algo::A
end
