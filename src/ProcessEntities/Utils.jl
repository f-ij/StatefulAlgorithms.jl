"""
Run one real `step!` call for profiling and return only its concrete return type.

This executes the underlying step logic, so it may mutate buffers reachable from
`context`.

For plain `ProcessEntity`s this runs `step!(pe, context)`. Wrapper types can specialize
`_profile_step_algo` / `_profile_step_context` to profile a different underlying call.
"""
Base.@constprop :aggressive function profile_step_return(pe::ProcessEntity, context)
    profiled_context = @inline _profile_step_context(pe, context)
    retval = @inline step!(_profile_step_algo(pe), profiled_context)
    return typeof(retval)
end

@inline _profile_step_algo(pe::ProcessEntity) = pe
@inline _profile_step_context(pe::ProcessEntity, context) = context
