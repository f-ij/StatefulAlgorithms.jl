#=
The state context of a `Process`: how a run's result, an init's context or the user's (`setcontext!`) becomes the
process's state, and whether that state is kept in the plan (typed) or in `p.state_context`.
=#

"""
    _sync_state_context!(p, c)

Makes the values of `c` the process's state: a run's persistent context when it ends or pauses, or a context made by
init. The values (the subcontexts of `c`) go into the process's state context, which keeps everything else of the
user's handle (the registry). When the result has the type of the context stored in the plan, the plan's lifecycle
wrapper in `p.algo` is rebuilt with it, so later runs keep the typed path; otherwise it goes to `p.state_context`.
Leaves a paused run's runtime context alone.
"""
@inline function _sync_state_context!(p::P, c::C) where {P<:Process, C<:ProcessContext}
    synced = withsubcontexts(getcontext(p), get_subcontexts(c))
    algo = getalgo(p)
    persistent_context = getpersistentcontext(algo)
    if !isnothing(persistent_context) && typeof(synced) === typeof(persistent_context)
        p.algo = _with_lifecycle(algo, synced, getstoredinits(algo), getstoredoverrides(algo))
        p.state_context = nothing
    else
        p.state_context = synced
    end
    return synced
end

"""
    setcontext!(p::Process, c) -> the process's new state context

Makes the values of `c` the state of `p` (`_sync_state_context!`). A running process is paused first and resumed after,
so the values never race the loop, and the run goes on from them with its own runtime values (inputs, declared locals).
A paused process resumes from them later; an idle one starts its next run from them.
"""
function setcontext!(p::P, c::C) where {P<:Process, C<:ProcessContext}
    wasrunning = isrunning(p)
    if wasrunning
        pause(p)
        wait(p)
    end
    synced = _sync_state_context!(p, c)
    wasrunning && run(p)
    return synced
end

@inline _has_typed_state_context(p::P) where {P<:Process} = isnothing(p.state_context)
@inline _typed_state_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))
