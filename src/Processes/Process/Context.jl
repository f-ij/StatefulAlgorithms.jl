#=
The state context of a `Process`: how a run's result or an init's context becomes the process's state, and whether that
state is kept in the plan (typed) or in `p.state_context`.
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

# A `Process` manages its state context: the new context's values go into it.
makecontext!(p::Process, inputs_overrides...; lifetime=nothing) = _sync_state_context!(p, makecontext(p, inputs_overrides...; lifetime))

@inline _has_typed_state_context(p::P) where {P<:Process} = isnothing(p.state_context)
@inline _typed_state_context(p::P) where {P<:Process} = getpersistentcontext(getalgo(p))
