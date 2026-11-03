#=
Getters and setters of `Process`: its session's flags and counters, its plan and context, its times, its lock and the
processes linked to it.
=#

"""The lifetime later runs of `p` get when `run` is given none."""
@inline lifetime(p::P) where {P<:Process} = getfield(p, :lifetime)

"""
    getloopcursor(p::Process)

Return the loop cursor stored by a paused run, always as the plan's cursor type `C`.
Throws a `TypeError` when no cursor is stored.
"""
@inline getloopcursor(p::Process{F,C}) where {F,C} = getsession(p).loop_cursor::C

"""Whether the process should run (`false` after `pause(p)` or `close(p)`): its session's `shouldrun` flag."""
shouldrun(p::Process) = shouldrun(getsession(p))
"""Set whether the process should run."""
shouldrun(p::Process, val) = @atomic getsession(p).shouldrun = val

@inline getticks(p::Process) = getsession(p).tickidx
@inline reset_ticks!(p::Process) = (getsession(p).tickidx = UInt(1))

getalgo(p::P) where {P<:Process} = p.algo
"""
    context(p::Process)

The process's state context: the user's handle on the process's state, with the registry. Never a run's runtime
context: a paused run keeps that apart (`p.runtime_context`).
"""
function context(p::P) where {P<:Process}
    state_context = p.state_context
    return isnothing(state_context) ? getpersistentcontext(getalgo(p)) : state_context
end

"""
    getruntimecontext(p::Process)

The runtime context a paused run of `p` keeps (its inputs and declared locals), or `nothing` when no run is paused.
Not exported: what the user works with is the state context, `context(p)`.
"""
getruntimecontext(p::Process) = p.runtime_context

runtimelisteners(p::Process) = p.rls

isthreaded(p::Process) = true

"""
different loopfunction can be passed to the process through overrides
"""
function getloopfunc(p::Process)
    loop
end

function runtime(p::Process)
    @assert !isnothing(getsession(p).starttime) "Process has not started"
    return runtime_ns(p) / 1e9
end

function runtime_ns(p::Process)
    session = getsession(p)
    @assert !isnothing(session.starttime) "Process has not started"
    timens = isnothing(session.endtime) ? time_ns() - session.starttime : session.endtime - session.starttime
    return Int(timens)
end
export runtime_ns, runtime

# Exact time the process stopped in hh:mm:ss
function stop_time(p::Process)
    if isdone(p)
        return Dates.format(Dates.DateTime(getsession(p).endtime), "HH:MM:SS")
    else
        return nothing
    end
end

@inline lock(p::Process) = lock(p.lock)
@inline lock(f, p::Process) = lock(f, p.lock)
@inline unlock(p::Process) =  unlock(p.lock)

### LINKING

link_process!(p1::Process, p2::Process) = push!(p1.linked_processes, p2)
unlink_process!(p1::Process, p2::Process) = filter!(x -> x != p2, p1.linked_processes)
