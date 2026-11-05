#=
Starting and ending a `Process` run. `run(p)` calls `_start_run!`; the task it starts runs `_run_loop_and_store!`.
`prepare_for_loop` is also used by `TimedProcess`.
=#

"""
    prepare_for_loop(p::Process, context, inputs, lifetime, resume)

Run at the start of every run. Gives the session, the plan and the `LoopContext` to start from: the state context
plus the run's inputs, or, when resuming, plus the runtime context the pause kept.
"""
function prepare_for_loop(p::InteractiveProcess, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{false}) where {C<:ProcessContext, LT}
    session = getsession(p)
    func = getalgo(p)
    return session, func, with_inputs(LoopContext(func, context), func, inputs)
end

function prepare_for_loop(p::InteractiveProcess, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{true}) where {C<:ProcessContext, LT}
    session = getsession(p)
    func = getalgo(p)
    runtime_context = p.runtime_context
    p.runtime_context = nothing
    return session, func, LoopContext(context, runtime_context)
end

"""
    _start_run!(p, inputs; resume, threaded = true, loopfunc = loop)

Called by `run(p)`: starts a new run (`resume = false`) or resumes a paused one on a task of its own. `loopfunc`
replaces `loop` for tests that look at what the loop gets.
"""
function _start_run!(p::Process, inputs::NamedTuple = (;); resume::Bool = false, threaded::Bool = true, loopfunc::LF = loop) where {LF}
    resume && wait(p)
    lt = getlifetime(p)
    resuming = resume ? Resuming{true}() : Resuming{false}()
    session, func, lc = prepare_for_loop(p, getcontext(p), inputs, lt, resuming)
    # A resumed run clears the pause flag in the loop, after reading the cursor the pause kept.
    resume || @atomic session.paused = false
    @atomic session.shouldrun = true
    p.lastresult = nothing
    task = Task(() -> _run_loop_and_store!(p, loopfunc, session, func, lc, lt, resuming))
    if threaded
        task.sticky = false
        Threads._spawn_set_thrpool(task, :default)
    end
    p.task = schedule(task)
    return p
end

"""
What the task of a run executes: the loop, then `_store_run_contexts!`. Its return value is what `fetch(p)` gives. A
function of its own so it can be precompiled per process type (PrecompileInterface.jl).
"""
function _run_loop_and_store!(p::P, loopfunc::LF, session::S, func::F, lc::LC, lt::LT, resume::R) where {P<:Process, LF, S<:InteractiveSession, F, LC<:LoopContext, LT, R<:Resuming}
    persistent_context, returnvalue = run_session_loop(loopfunc, session, func, lc, lt, resume)
    return _store_run_contexts!(p, session, persistent_context, returnvalue)
end

"""
    _store_run_contexts!(p, session, persistent_context, returnvalue) -> what `fetch(p)` gives

Run when a run stops, paused or done: the loop returns its contexts and the process has to keep them. Paused: the
state goes into the state context, the runtime context into `p.runtime_context`, for the resume. Done: the state goes
into the state context and the cursor is dropped.
"""
function _store_run_contexts!(p::Process, session::InteractiveSession, persistent_context, returnvalue)
    if loop_ispaused(session)
        _sync_state_context!(p, getpersistent(returnvalue))
        p.runtime_context = getruntime(returnvalue)
        return getcontext(p)
    end
    _sync_state_context!(p, persistent_context)
    session.loop_cursor = nothing
    return returnvalue
end

"""
    reset!(process)

Run before running a process again from the start without new init (the manager's `resetworker!`): the next run starts
at step 1 with fresh counters and loop cursor. The context is kept as it is. A `Package`'s own interval counter is not
reset (TODO.md, "Packaging and threaded composites").
"""
function reset!(p::Process)
    session = getsession(p)
    reset_loopidx!(session)
    reset_ticks!(p)
    session.loop_cursor = nothing
    @atomic session.paused = false
    @atomic session.shouldrun = true
    reset_times!(session)
    return p
end
