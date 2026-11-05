#=
Copying a `Process`: the `InitArgs`/`Override` specs its context is set up from (`copyinputs`, `copyoverrides`) and a new process
from its plan and specs (`copyprocess`); making a process run another's plan and context (`createfrom!`).
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
    copyprocess(p::Process; lifetime, timeout, context) -> Process

A new process with `p`'s plan and stored specs, set up from them (every `init` runs). It takes no specs: other values
for the copy are a separate step, `init!(q, InitArgs(...), Override(...))` (or with `Only(...)` for some `init`). With
`context`, no `init` runs: the new process starts from that context with its values (for example
`deepcopy(getcontext(p))`, or `getcontext(p)` itself) and keeps `p`'s specs. It must have the shape of `p`'s context
(the same type). A process with another plan is `Process(plan, specs...)`: `p`'s specs are keyed by its own plan's
registry.
"""
function copyprocess(p::Process; lifetime = StatefulAlgorithms.getlifetime(p), timeout = p.timeout, context = nothing, kwargs...)
    isnothing(context) && return Process(getalgo(p), getspecs(p)...; lifetime, timeout)
    context = strip_keymap(context)   # a context from `getcontext` carries the `UniqueKeyMap`
    typeof(context) === typeof(_getcontext_nokeymap(p)) || throw(ArgumentError("copyprocess: `context` must have the shape of the process's context ($(typeof(_getcontext_nokeymap(p)))), got $(typeof(context))."))
    q = Process(getalgo(p); context, lifetime, timeout)
    q.specs = getspecs(p)
    return q
end

"""Make `p1` run `p2`'s plan, specs, state context and timeout, from the start."""
function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    p1.specs = getspecs(p2)
    _sync_state_context!(p1, _getcontext_nokeymap(p2))
    p1.runtime_context = nothing
    getsession(p1).loop_cursor = nothing
    p1.timeout = p2.timeout
    reset!(p1)
end
