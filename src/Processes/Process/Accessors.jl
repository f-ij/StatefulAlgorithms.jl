#=
Getters and setters of `Process`: its lifetime, its session's flags and counters, its plan and context, its listeners.
Operations that are not getters or setters (run time, locking, linking) live in Tools.jl.
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

export getticks
@inline getticks(p::Process) = getsession(p).tickidx
@inline reset_ticks!(p::Process) = (getsession(p).tickidx = UInt(1))

getalgo(p::P) where {P<:Process} = p.algo
"""
    getcontext(p::Process)

The process's state context: the user's handle on the process's state, with the registry. Never a run's runtime
context: a paused run keeps that apart (`p.runtime_context`).
"""
function getcontext(p::P) where {P<:Process}
    state_context = p.state_context
    return isnothing(state_context) ? getpersistentcontext(getalgo(p)) : state_context
end

"""
    getruntimecontext(p::Process)

The runtime context a paused run of `p` keeps (its inputs and declared locals), or `nothing` when no run is paused.
Not exported: what the user works with is the state context, `getcontext(p)`.
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
