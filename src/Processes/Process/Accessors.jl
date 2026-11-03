#=
Getters and setters of `Process`: its lifetime, its session's flags and counters, its plan, its state context
(`getcontext`, `setcontext!`, and `_sync_state_context!`, which stores a context's values in it), its listeners.
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
    setcontext!(p::Process, c) -> c

Store `c` as the process's state context. When `c` has the type of the context stored in the plan, the plan's lifecycle
wrapper in `p.algo` is rebuilt with it, so later runs keep the typed path; otherwise it goes to `p.state_context`.
Does not look at whether `p` runs: a caller that may race a running loop pauses it first.
"""
function setcontext!(p::P, c::C) where {P<:Process, C<:ProcessContext}
    algo = getalgo(p)
    persistent_context = getpersistentcontext(algo)
    if !isnothing(persistent_context) && typeof(c) === typeof(persistent_context)
        p.algo = _with_lifecycle(algo, c, getstoredinits(algo), getstoredoverrides(algo))
        p.state_context = nothing
    else
        p.state_context = c
    end
    return c
end

"""
    _sync_state_context!(p, c)

Makes the values of `c` the process's state: a run's persistent context when it ends or pauses, or a context made by
init. The values (the subcontexts of `c`) go into the process's state context, which keeps everything else of the
user's handle (the registry), and the result is stored with `setcontext!`. Leaves a paused run's runtime context alone.
"""
# TODO: this is the function to extend later so that it puts the data from the `LoopContext` into the user's handle
# context (the process keeps the handle's type, which matters once the registries are stripped before the loop).
@inline _sync_state_context!(p::P, c::C) where {P<:Process, C<:ProcessContext} =
    setcontext!(p, withsubcontexts(getcontext(p), get_subcontexts(c)))

@inline _has_typed_state_context(p::P) where {P<:Process} = isnothing(p.state_context)
@inline _typed_state_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))

"""
    getruntimecontext(p::Process)

The runtime context a paused run of `p` keeps (its inputs and declared locals), or `nothing` when no run is paused.
Not exported: what the user works with is the state context, `getcontext(p)`.
"""
getruntimecontext(p::Process) = p.runtime_context

runtimelisteners(p::Process) = p.rls
