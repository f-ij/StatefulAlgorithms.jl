#=
A `TimedProcess` run: the tick its timer runs (`_tick!`), which is one step of the plan as in the process loop
(Loops.jl), the lifetime's stop check after it (`_lifetime_over`), stopping the timer (`_stop_timer!`) and the run's
end (`_end_timed_run!`).
=#

"""
    _tick!(tp)

One tick of `tp`'s timer: one step of the plan (`_step!`) from the state context and the runtime context the process
keeps, which then keeps the step's. The run ends when its lifetime (`getlifetime(getsession(tp))`) is over after the step. A tick after a pause or
close does nothing.
"""
function _tick!(tp::TimedProcess)
    @lock tp.lock begin
        session = getsession(tp)
        shouldrun(session) || return nothing
        algo, lt = getalgo(tp), getlifetime(session)
        plan = getplan(algo)
        lc = _step!(plan, getloopcursor(tp), LoopContext(getcontext(tp), getruntimecontext(tp)), _root_wiring_view(algo, plan), Namespace{nothing}(), session, lt)
        tick!(session)
        inc!(session)
        _sync_state_context!(tp, getpersistent(lc))
        tp.runtime_context = getruntime(lc)
        if _lifetime_over(lt, lc, session)
            _stop_timer!(tp, false)
            _end_timed_run!(tp)
        end
    end
    return nothing
end

"""
Whether a run with lifetime `lt` stops before its next step: its repeats are done or its own condition holds
(`lifetime_breakcondition`), the two checks the process loop makes before every step (Loops.jl).
"""
@inline function _lifetime_over(lt::LT, lc::LC, session::S) where {LT<:Lifetime, LC<:LoopContext, S<:InteractiveSession}
    done = loopint(session) - 1
    return done >= repeats(lt) || lifetime_breakcondition(lt, final_context(lc), done)
end

"""
Stops `tp`'s timer and sets its session's flags: not running, and paused when `paused`. A tick going on sees it
after its routine repeats (`session_breakcondition`), as a `Process` run does.
"""
function _stop_timer!(tp::TimedProcess, paused::Bool)
    session = getsession(tp)
    @atomic session.paused = paused
    @atomic session.shouldrun = false
    timer = tp.timer
    isnothing(timer) || close(timer)
    tp.timer = nothing
    return nothing
end

"""
Ends the run of `tp`: cleanup on its kept contexts and the final result in `tp.lastresult`
(`_cleanup_paused_process!`); the cursor is dropped and the end time recorded.
"""
function _end_timed_run!(tp::TimedProcess)
    _cleanup_paused_process!(tp)
    session = getsession(tp)
    session.loop_cursor = nothing
    set_endtime!(session)
    return nothing
end
