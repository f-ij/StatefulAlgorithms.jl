#=
Copying a `Process`: its stored `Init`/`Override` specs (`copyinputs`, `copyoverrides`) and a new process from its
initialized plan, or from a plan (`copyprocess`); making a process run another's plan and context (`createfrom!`).
=#

export copyprocess

@inline copyinputs(p::Process) = copyinputs(getalgo(p))
@inline copyoverrides(p::Process) = copyoverrides(getalgo(p))

"""
    copyprocess(p::Process, Init(...), Override(...); kwargs...)

Build a new process from the stored initialized loop algorithm recipe. Extra
init/override specs are merged by `init`.
"""
function copyprocess(p::Process, specs...; lifetime = StatefulAlgorithms.lifetime(p), timeout = p.timeout, context = nothing, func = getalgo(p), kwargs...)
    algo = isnothing(context) ? init(func, specs...) : _with_lifecycle(resolve(func), context, copyinputs(func), copyoverrides(func))
    return Process(algo; lifetime, timeout)
end

copyprocess(la::ALA, specs...; lifetime = Indefinite(), timeout = 1.0, context = nothing, kwargs...) where {ALA<:AbstractLoopAlgorithm} =
    Process(isnothing(context) ? init(la, specs...) : _with_lifecycle(resolve(la), context, copyinputs(la), copyoverrides(la)); lifetime, timeout)

"""Make `p1` run `p2`'s plan, state context and timeout, from the start."""
function createfrom!(p1::Process, p2::Process)
    p1.algo = p2.algo
    _sync_state_context!(p1, getcontext(p2))
    p1.runtime_context = nothing
    getsession(p1).loop_cursor = nothing
    p1.timeout = p2.timeout
    reset!(p1)
end
