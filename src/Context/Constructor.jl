"""
    ProcessContext(registry)

Construct an empty context based on the registry spec: one empty `SubContext` per registered name. No init runs.
"""
function ProcessContext(registry::R) where {R<:NameSpaceRegistry}
    registered_keys = all_keys(registry)
    subcontexts = ntuple(i -> SubContext(registered_keys[i], (;)), length(registered_keys))
    return ProcessContext(NamedTuple{registered_keys}(subcontexts), registry)
end

"""
    ProcessContext(plan)

Construct an empty context for `plan` (see `ProcessContext(registry)`). Resolving an already resolved plan is a no-op.
"""
ProcessContext(la::LA) where {LA<:LoopSpec} = ProcessContext(getregistry(resolve(la)))
