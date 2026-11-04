#=
Copying a `Process`: the `Init`/`Override` specs it was built with (`copyinputs`, `copyoverrides`) and a new process
from its plan and specs, or from a plan (`copyprocess`); making a process run another's plan and context (`createfrom!`).
=#

export copyprocess, copyinputs, copyoverrides

"""
    copyinputs(p)

The `Init` specs `p` was built with.
"""
@inline copyinputs(p::Process) = filter_by_type(Input, getspecs(p))

"""
    copyoverrides(p)

The `Override` and `Interactive` specs `p` was built with.
"""
@inline copyoverrides(p::Process) = (filter_by_type(Override, getspecs(p))..., filter_by_type(Interactive, getspecs(p))...)

"""
    copyprocess(p::Process, Init(...), Override(...); kwargs...)

A new process with `p`'s plan, set up from the specs `p` was built with and the new ones (later specs win per target).
With `context`, the new process starts from it and keeps `p`'s specs.
"""
function copyprocess(p::Process, specs...; lifetime = StatefulAlgorithms.lifetime(p), timeout = p.timeout, context = nothing, func = getalgo(p), kwargs...)
    isnothing(context) && return Process(func, getspecs(p)..., specs...; lifetime, timeout)
    q = Process(func; context, lifetime, timeout)
    q.specs = getspecs(p)
    return q
end

copyprocess(la::ALA, specs...; lifetime = Indefinite(), timeout = 1.0, context = nothing, kwargs...) where {ALA<:AbstractLoopAlgorithm} =
    isnothing(context) ? Process(la, specs...; lifetime, timeout) : Process(la; context, lifetime, timeout)

"""Make `p1` run `p2`'s plan, specs, state context and timeout, from the start."""
function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    p1.specs = getspecs(p2)
    _sync_state_context!(p1, getcontext(p2))
    p1.runtime_context = nothing
    getsession(p1).loop_cursor = nothing
    p1.timeout = p2.timeout
    reset!(p1)
end
