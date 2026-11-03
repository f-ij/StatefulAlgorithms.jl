#=
Loop setup of a `Process`: what a run hands to the loop (`prepare_for_loop`, `create_session`), the task that runs it,
what happens on a pause or end (`_finish_run!`), resuming a paused run, and `reset!`.
=#

"""
Runs the prepared task of a process on a thread
"""
function makeloop!(p::Process, inputs::NamedTuple = (;); threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_state_context(p)
        return _makeloop!(p, inputs, lifetime(p), _typed_state_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs; threaded, loopfunc)
    end
end

function makeloop!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF}
    if _has_typed_state_context(p)
        return _makeloop!(p, inputs, lt, _typed_state_context(p); threaded, loopfunc)
    else
        return _makeloop_dynamic!(p, inputs, lt; threaded, loopfunc)
    end
end

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lifetime(p), StatefulAlgorithms.context(p); threaded, loopfunc)

@noinline _makeloop_dynamic!(p::Process, inputs::NamedTuple, lt; threaded = true, loopfunc::LF = loop) where {LF} =
    _makeloop!(p, inputs, lt, StatefulAlgorithms.context(p); threaded, loopfunc)

function _makeloop!(p::Process, inputs::NamedTuple, lt, base_context; threaded = true, loopfunc::LF = loop) where {LF}
    session, func, lc = prepare_for_loop(p, base_context, inputs, lt, Resuming{false}())
    return _start_run!(p, session, func, lc, lt; threaded, loopfunc)
end

"""
    prepare_for_loop(p::Process, context, inputs, lifetime, resume)

A `Process` run runs in the process's session when it has `lifetime`'s type, else in a new one with the same counters
(`create_session`), which becomes the process's session. A new run starts from `context` (the process's state context)
and the run's inputs. A resumed run starts from `context` and the runtime context its pause kept, combined again into
one `LoopContext`; the process no longer keeps that runtime context (Processes/Hooks.jl).
"""
function prepare_for_loop(p::Process, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{false}) where {C<:ProcessContext, LT}
    session = create_session(p, lt)
    p.session = session
    func = getalgo(p)
    return session, func, with_inputs(LoopContext(func, context), func, inputs)
end

function prepare_for_loop(p::Process, context::C, inputs::NamedTuple, lt::LT, resume::Resuming{true}) where {C<:ProcessContext, LT}
    session = create_session(p, lt)
    p.session = session
    func = getalgo(p)
    runtime_context = p.runtime_context
    p.runtime_context = nothing
    return session, func, LoopContext(context, runtime_context)
end

"""
    create_session(p, lifetime) -> InteractiveSession

The session a run of `p` with `lifetime` runs in: the process's session when it has that lifetime's type, else a new
one with the same counters, times and thread. The caller sets it as the process's session, never while a run is going
on, so the loop and the process always share the one session.
"""
function create_session(p::Process{F, C}, lt::LT) where {F, C, LT}
    session = getsession(p)
    session isa InteractiveSession{C, LT} && return session
    return InteractiveSession{C, LT}(@atomic(session.shouldrun), @atomic(session.paused), session.loopidx, session.tickidx,
        session.starttime, session.endtime, session.loop_cursor, session.threadid)
end

"""
    _start_run!(p, session, func, loop_context, lifetime; threaded, loopfunc, resume)

Starts a run of `p` with what `prepare_for_loop` made: the session is set running, then the task running the loop is
scheduled.
"""
function _start_run!(p::P, session::S, func::F, lc::LC, lt::LT; threaded::Bool = true, loopfunc::LF = loop, resume::R = Resuming{false}()) where {P<:Process, S<:InteractiveSession, F, LC<:LoopContext, LT, LF, isresuming, R<:Resuming{isresuming}}
    # A resumed run clears the pause flag in the loop, after reading the cursor the pause kept.
    isresuming || @atomic session.paused = false
    @atomic session.shouldrun = true
    p.lastresult = nothing
    wait_loop_precompile!(p, func, lc, lt, resume; loopfunc)
    # The task runs `body` itself (as `Threads.@spawn` and `@async` do with a closure around it): its type is known
    # before the task exists, so it can be compiled ahead (Processes/Process/Precompile.jl).
    body = ProcessTaskBody(p, loopfunc, session, func, lc, lt, resume)
    task = Task(body)
    if threaded
        task.sticky = false
        Threads._spawn_set_thrpool(task, :default)
    end
    p.task = schedule(task)
    return p
end

"""
    ProcessTaskBody(p, loopfunc, session, func, loop_context, lifetime, resume)

What a `Process` task runs, as a value: calling it runs `_run_process_task` with its fields. A struct, not a closure,
so its type is known before the task exists.
"""
struct ProcessTaskBody{P, LF, S, F, LC, LT, R}
    p::P
    loopfunc::LF
    session::S
    func::F
    loop_context::LC
    lifetime::LT
    resume::R
end
(body::ProcessTaskBody)() = _run_process_task(body.p, body.loopfunc, body.session, body.func, body.loop_context, body.lifetime, body.resume)

"""
What a `Process` task runs: the loop on the session (`run_session_loop`), then the run's end on the process
(`_finish_run!`). Its result is what `fetch(p)` returns.
"""
function _run_process_task(p::P, loopfunc::LF, session::S, func::F, lc::LC, lt::LT, resume::R) where {P<:Process, LF, S<:InteractiveSession, F, LC<:LoopContext, LT, R<:Resuming}
    persistent_context, returnvalue = run_session_loop(loopfunc, session, func, lc, lt, resume)
    return _finish_run!(p, session, persistent_context, returnvalue)
end

"""
    _finish_run!(p, session, persistent_context, returnvalue) -> what the user gets (`fetch(p)`)

A run's end on the process. On a pause the loop gives back its `LoopContext` as `returnvalue`, and it is taken apart:
the persistent context's values go into the process's state context (`_sync_state_context!`), the runtime context into
`p.runtime_context`; the cursor is kept by the loop in the session. The run resumes from these and the user gets the
state context. Otherwise the persistent context's values go into the state context and the cursor is dropped.
"""
function _finish_run!(p::Process, session::InteractiveSession, persistent_context, returnvalue)
    if loop_ispaused(session)
        _sync_state_context!(p, getpersistent(returnvalue))
        p.runtime_context = getruntime(returnvalue)
        return context(p)
    end
    _sync_state_context!(p, persistent_context)
    session.loop_cursor = nothing
    return returnvalue
end

function _resume_paused_loop!(p::Process; threaded = true)
    wait(p)
    lt = lifetime(p)
    session, func, lc = prepare_for_loop(p, StatefulAlgorithms.context(p), (;), lt, Resuming{true}())
    return _start_run!(p, session, func, lc, lt; threaded, resume = Resuming{true}())
end

makeloop!(p::Process, lt::Lifetime; threaded = true, loopfunc::LF = loop) where {LF} =
    makeloop!(p, (;), lt; threaded, loopfunc)

"""
    reset!(process)

Reset selected `Process` fields without rebuilding its context.

This performs these exact mutations:

- in its session (`getsession(process)`): `loopidx = 1`, `tickidx = 1`, `paused = false`, `shouldrun = true`,
  `starttime = nothing`, `endtime = nothing`, and `loop_cursor = nothing`: the next run builds a fresh cursor, so every
  interval counter and resume point starts over.

It does not reset counters an algorithm keeps in its own value: a `Package`'s interval counter goes on from where it
was (TODO.md, "Packaging and threaded composites"). It does not change `process.state_context`, `process.runtime_context`, `process.task`, or
`process.lastresult`. It does not clear or replace values stored in
`context(process)`.
"""
function reset!(p::Process)
    session = getsession(p)
    reset_loopidx!(session)
    session.tickidx = UInt(1)
    session.loop_cursor = nothing
    @atomic session.paused = false
    @atomic session.shouldrun = true
    reset_times!(session)
    return p
end
