"""
    profile_step_return(pe, bundle)

Run one real `step!` call of `pe` on the context bundle `bundle` (a `LoopContext`, e.g. `bundle_of(context)`) and
return only the type of what the step returned.

This executes the underlying step logic, so it may mutate buffers reachable from
`bundle`.

For a plain `ProcessEntity` this runs `step!(pe, bundle)`; a keyed algorithm steps its inner
algorithm on its view of `bundle`.
"""
Base.@constprop :aggressive function profile_step_return(pe::PE, bundle::B) where {PE<:ProcessEntity, B}
    return typeof(@inline step!(pe, bundle))
end
