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

Construct an empty context for `plan` (see `ProcessContext(registry)`). An unresolved plan is resolved here, with a
warning: resolve it first so the work is not repeated by every caller.
"""
function ProcessContext(la::LA) where {LA<:LoopSpec}
    isresolved(la) || @warn "ProcessContext got an unresolved plan and resolves it here; call `resolve(plan)` first so this is not repeated." maxlog = 1
    return ProcessContext(getregistry(resolve(la)))
end
