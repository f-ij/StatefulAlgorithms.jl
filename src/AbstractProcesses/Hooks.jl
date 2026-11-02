#=
Extendable API of what runs a loop (a process, or a plan run directly): what a run hands to the loop.

Extended in:
- Process.jl: `Process` (a session for the run's lifetime, the plan without the map, its context or the paused one);
- InlineProcess.jl: `InlineProcess` (its one session, its plan and context kept without the map);
- LoopAlgorithms/HookExtensions.jl: a plan run directly (`run(plan)`: a new `InlineSession`).
=#

"""
    prepare_loop(owner, inputs, lifetime, resume) -> (session, plan, loop_context)

What a run of `owner` hands to the loop, made from what the user holds: the session the run runs in, the plan the loop
runs (without the plan's `UniqueKeyMap` where the owner keeps one) and the `LoopContext` the run starts from (made by its
constructor from the owner's context and the run's `inputs`; the map is dropped there). With the run's `lifetime` they
are the loop's arguments: `run_session_loop(session, plan, loop_context, lifetime, resume)`. `resume` is
`Resuming{true}()` when a paused run resumes. The first call of every run: `run(ip)`, `run(p)` and its resume, the
manager's inline run, `run(plan)`.
"""
function prepare_loop end
