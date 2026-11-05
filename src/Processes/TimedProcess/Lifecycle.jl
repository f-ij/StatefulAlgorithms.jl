#=
What a user calls on a `TimedProcess`: `run`, `pause`, `close`, `fetch` and `init!`.
=#

"""
    run(tp::TimedProcess; inputs...)

Starts `tp`'s timer, which runs a step every `interval` seconds, the first one now. A new run starts from the state
context and the run's inputs, as a `Process` run does (`prepare_for_loop`), and keeps the run's runtime context and a
new cursor on the process; a paused run resumes from what its pause kept. The run's lifetime is `getlifetime(tp)`
(change it with `setlifetime!`).
"""
function Base.run(tp::TimedProcess; kwargs...)
    isrunning(tp) && error("TimedProcess is already running.")
    _reject_run_lifetime(kwargs)
    if ispaused(tp)
        isempty(kwargs) || error("Cannot pass new runtime inputs while resuming a paused TimedProcess.")
    else
        session, algo, lc = prepare_for_loop(tp, getcontext(tp), (; kwargs...), StatefulAlgorithms.getlifetime(tp), Resuming{false}())
        session.loop_cursor = starting_cursor(session, getplan(algo), Resuming{false}())
        tp.runtime_context = getruntime(lc)
        before_while(session)
        if _lifetime_over(StatefulAlgorithms.getlifetime(tp), lc, session)
            _end_timed_run!(tp)
            return tp
        end
    end
    session = getsession(tp)
    @atomic session.paused = false
    @atomic session.shouldrun = true
    tp.timer = Timer(_ -> _tick!(tp), 0; interval = tp.interval)
    return tp
end

"""Pauses `tp`: its timer stops, after the tick going on; `run(tp)` resumes."""
function pause(tp::TimedProcess)
    _stop_timer!(tp, true)
    @lock tp.lock nothing
    return true
end

"""Closes `tp`: its timer stops and a running or paused run ends (`_end_timed_run!`); the loop counter starts over."""
function Base.close(tp::TimedProcess)
    _stop_timer!(tp, false)
    @lock tp.lock begin
        isnothing(getruntimecontext(tp)) || _end_timed_run!(tp)
        reset_loopidx!(getsession(tp))
    end
    return true
end

"""The final result of `tp`'s last run that ended, `nothing` before one has."""
Base.fetch(tp::TimedProcess) = tp.lastresult

"""
    init!(tp, InitArgs(...), Override(...)) -> tp
    init!(tp, Only(A, B), InitArgs(...), Override(...)) -> tp

As `init!(p::Process, ...)`: runs `init` again (all of them, or the ones `Only` names) and makes the result the
process's state. A running timer is paused for it and started again after.
"""
function init!(tp::TimedProcess, specs::InputInterface...)
    was_running = isrunning(tp)
    was_running && pause(tp)
    context, stored = _init_process_context(tp, specs)
    _sync_state_context!(tp, context)
    tp.specs = stored
    was_running && run(tp)
    return tp
end
