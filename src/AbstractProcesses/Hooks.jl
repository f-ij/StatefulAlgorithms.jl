#=
Extendable API of what runs a loop (a process, or a plan run directly): what a run hands to the loop.

Extended in:
- Process.jl: `Process` (a session for the run's lifetime, its plan, the context it starts from or the paused one);
- InlineProcess.jl: `InlineProcess` (its one session, its plan and context);
- LoopAlgorithms/HookExtensions.jl: a plan run directly (`run(plan)`: a new `InlineSession`).
=#

"""
    _prepare_for_loop(owner, context, inputs, lifetime, resume) -> (session, plan, loop_context)

Everything a run of `owner` hands to the loop, made from what the user holds: the session the run runs in, the plan the
loop runs and the `LoopContext` the run starts from (made by the `LoopContext(plan, context, inputs, resume)`
constructor from `context` and the run's `inputs`). With the run's `lifetime` they are the loop's arguments:
`run_session_loop(session, plan, loop_context, lifetime, resume)`. `resume` is `Resuming{true}()` when a paused run
resumes. The first call of every run: `run(ip)`, `run(p)` and its resume, the manager's inline run, `run(plan)`. What
the loop does not need of the user's handle is left out here, so this is where it is dropped.
"""
function _prepare_for_loop end
