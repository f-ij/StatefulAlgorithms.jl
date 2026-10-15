"""
    profile_step_return(pe, bundle)

Run one real `step!` call of `pe` on the context bundle `bundle` (a `LoopContext`, e.g. `bundle_of(context)`) and
return only the type of what the step returned.

This executes the underlying step logic, so it may mutate buffers reachable from
`bundle`.

For plain `ProcessEntity`s this runs `step!(pe, bundle)`. Wrapper types can specialize
`_profile_step_algo` / `_profile_step_context` to profile a different underlying call
(a keyed algorithm steps on its view of `bundle`).
"""
Base.@constprop :aggressive function profile_step_return(pe::ProcessEntity, bundle)
    profiled_context = @inline _profile_step_context(pe, bundle)
    retval = @inline step!(_profile_step_algo(pe), profiled_context)
    return typeof(retval)
end

@inline _profile_step_algo(pe::ProcessEntity) = pe
@inline _profile_step_context(pe::ProcessEntity, bundle) = bundle
