#=
Getters and setters of `Process`: its lifetime, its session's flags and counters, its plan, its state context
(`getcontext`, `setcontext!`, and `_sync_state_context!`, which stores a context's values in it), its listeners. All but
the listeners are written for `InteractiveProcess`, so a `TimedProcess` uses them too.
Operations that are not getters or setters (run time, locking, linking) live in Tools.jl.
=#

"""The lifetime of `p`'s runs that are given none (`run(p; repeats/lifetime)` gives one); changed with `setlifetime!`."""
@inline getlifetime(p::P) where {P<:InteractiveProcess} = getfield(p, :default_lifetime)

"""
    getloopcursor(p::InteractiveProcess)

Return the loop cursor stored by a paused run, always as the plan's cursor type `C`.
Throws a `TypeError` when no cursor is stored.
"""
@inline getloopcursor(p::InteractiveProcess{F,C}) where {F,C} = getsession(p).loop_cursor::C

"""Whether the process should run (`false` after `pause(p)` or `close(p)`): its session's `shouldrun` flag."""
shouldrun(p::InteractiveProcess) = shouldrun(getsession(p))
"""Set whether the process should run."""
shouldrun(p::InteractiveProcess, val) = @atomic getsession(p).shouldrun = val

export getticks
@inline getticks(p::InteractiveProcess) = getsession(p).tickidx
@inline reset_ticks!(p::InteractiveProcess) = (getsession(p).tickidx = UInt(1))

getalgo(p::P) where {P<:InteractiveProcess} = p.algo
"""
    getcontext(p::InteractiveProcess)

The process's state context: the user's handle on the process's state, with the plan's registry, so a `Unique` handle
the user holds is a key found from types (`getcontext(p)[handle]`). Never a run's runtime context: a paused run keeps
that apart (`p.runtime_context`).
"""
getcontext(p::P) where {P<:InteractiveProcess} = p.state_context

"""
    setcontext!(p::InteractiveProcess, c) -> c

Store `c` as the process's state context. Does not look at whether `p` runs: a caller that may race a running loop
pauses it first.
"""
setcontext!(p::P, c::C) where {P<:InteractiveProcess, C<:ProcessContext} = (p.state_context = c)

"""
    setlifetime!(p, lt) -> p

Makes `lt` the lifetime of `p`'s later runs that are given none (`Process`, `TimedProcess`; an `InlineProcess` has
`setlifetime`). A running or paused run keeps the lifetime it started with (a warning says so).
"""
function setlifetime!(p::P, lt::LT) where {P<:InteractiveProcess, LT<:Lifetime}
    (isrunning(p) || ispaused(p)) && @warn "setlifetime!: the run going on keeps its lifetime; `$lt` is for the next run."
    p.default_lifetime = lt
    return p
end

"""
    setlifetime(p::Process, lt) -> Process

A new `Process` with `p`'s plan, specs, timeout and context (the same context object, not a copy) and lifetime `lt`.
"""
setlifetime(p::Process, lt::LT) where {LT<:Lifetime} = copyprocess(p; lifetime = lt, context = getcontext(p))

"""
    _sync_state_context!(p, c)

Makes the values of `c` the process's state: a run's persistent context when it ends or pauses, or a context made by
init. The values (the subcontexts of `c`) go into the process's state context, which keeps everything else of the
user's handle (the registry), and the result is stored with `setcontext!`. Leaves a paused run's runtime context alone.
"""
# TODO: this is the function to extend later so that it puts the data from the `LoopContext` into the user's handle
# context (the process keeps the handle's type, which matters once the registries are stripped before the loop).
@inline _sync_state_context!(p::P, c::C) where {P<:InteractiveProcess, C<:ProcessContext} =
    setcontext!(p, withsubcontexts(getcontext(p), get_subcontexts(c)))

"""The `InitArgs`/`Override`/`Interactive` specs the process's context is set up from: those it was built with, merged
with those of later `init!` calls (resolved, one per target and kind)."""
getspecs(p::P) where {P<:InteractiveProcess} = p.specs

"""
    getruntimecontext(p::InteractiveProcess)

The runtime context a paused run of `p` keeps (its inputs and declared locals), or `nothing` when no run is paused.
Not exported: what the user works with is the state context, `getcontext(p)`.
"""
getruntimecontext(p::InteractiveProcess) = p.runtime_context

runtimelisteners(p::Process) = p.rls
