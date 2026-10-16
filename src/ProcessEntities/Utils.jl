"""
    profile_step_return(pe, bundle)

Run one real `step!` call of `pe` on the context bundle `bundle` (a `LoopContext`, e.g. `bundle_of(context)`) and
return only the type of what the step returned.

This executes the underlying step logic, so it may mutate buffers reachable from
`bundle`.

For plain `ProcessEntity`s this runs `step!(pe, bundle)`. Wrapper types specialize
`stepped_algo` / `stepped_context` so the wrapped algorithm is stepped instead
(a keyed algorithm steps its inner algorithm on its view of `bundle`).
"""
Base.@constprop :aggressive function profile_step_return(pe::ProcessEntity, bundle)
    retval = @inline step!(stepped_algo(pe), stepped_context(pe, bundle))
    return typeof(retval)
end

"""
    stepped_algo(pe)

Return the algorithm whose `step!` actually runs when `pe` steps: `pe` itself, or the
algorithm a wrapper holds.
"""
@inline stepped_algo(pe::ProcessEntity) = pe

"""
    stepped_context(pe, bundle)

Return the context that `stepped_algo(pe)` steps on: `bundle` itself, or a wrapper's view of it.
"""
@inline stepped_context(pe::ProcessEntity, bundle) = bundle
