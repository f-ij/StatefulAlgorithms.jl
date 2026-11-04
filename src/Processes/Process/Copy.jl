#=
Copying a `Process`: the `InitArgs`/`Override` specs its context is set up from (`copyinputs`, `copyoverrides`) and a new process
from its plan and specs, or from a plan (`copyprocess`); making a process run another's plan and context (`createfrom!`).
=#

export copyprocess, copyinputs, copyoverrides

"""
    copyinputs(p)

The `InitArgs` specs `p`'s context is set up from (resolved, merged with later `init!` calls).
"""
@inline copyinputs(p::Process) = filter_by_type(InitArgs, getspecs(p))

"""
    copyoverrides(p)

The `Override` and `Interactive` specs `p`'s context is set up from.
"""
@inline copyoverrides(p::Process) = (filter_by_type(Override, getspecs(p))..., filter_by_type(Interactive, getspecs(p))...)

"""
    copyprocess(p::Process, InitArgs(...), Override(...); kwargs...)

A new process with `p`'s plan, set up from `p`'s stored specs and the new ones (later specs win per target).
With `context`, the new process starts from it and keeps `p`'s specs.
"""
function copyprocess(p::Process, specs...; lifetime = StatefulAlgorithms.lifetime(p), timeout = p.timeout, context = nothing, func = getalgo(p), kwargs...)
    # Another plan: its registry may name things otherwise, so the stored specs are resolved against it again.
    func === getalgo(p) || !isnothing(context) || return Process(func, getspecs(p)..., specs...; lifetime, timeout)
    # The same plan: the stored specs are already resolved, so they are merged without a lookup by name.
    inits, overrides, interactives = _merged_lifecycle_specs(getregistry(getalgo(p)), getspecs(p), specs)
    q = Process(func; context = something(context, _init_context_for(getalgo(p), inits, overrides, interactives, lifetime)), lifetime, timeout)
    q.specs = isnothing(context) ? (inits..., overrides..., interactives...) : getspecs(p)
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
