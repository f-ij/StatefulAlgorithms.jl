#=
Extendable API of what runs a loop (a process, or a plan run directly): what a run hands to the loop.

Extended in:
- Processes/Process/Loop.jl: `Process` and `TimedProcess` (`InteractiveProcess`: its session, its plan, the
  context it starts from or the paused one);
- Processes/InlineProcess/Loop.jl: `InlineProcess` (its one session, its plan and context);
- LoopAlgorithms/DirectRuns.jl: a plan run directly (`run(plan)`: a new `InlineSession`).
=#

"""
    prepare_for_loop(owner, context, inputs, resume) -> (session, plan, loop_context)

Everything a run of `owner` hands to the loop, made from what the user holds: the session the run runs in, the plan the
loop runs and the `LoopContext` the run starts from. A new run's is `LoopContext(plan, context)` with the run's
`inputs` added by `with_inputs`, which checks them against the plan's `@input`s; a resumed run's is
`LoopContext(context, runtime_context)` with the runtime context its pause kept. With the run's lifetime (a `Process` or
`TimedProcess` run's is `session.lifetime`) they are the loop's arguments:
`run_session_loop(session, plan, loop_context, lifetime, resume)`. `resume` is `Resuming{true}()` when a paused run
resumes. The first call of every run: `run(ip)`, `run(p)` and its resume, the manager's inline run, `run(plan)`. What
the loop does not need of the user's handle is left out here, so this is where it is dropped.
"""
function prepare_for_loop end
