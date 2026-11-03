"""
Set up an empty `ProcessContext` from a resolved registry.

Route/share metadata is intentionally not embedded in `SubContext`; plan wiring
is supplied to `SubContextView` during `step!`.
"""
function _build_process_context(registry::R) where {R<:NameSpaceRegistry}

    # Create Subcontexts from registry
    registered_keys = all_keys(registry)
    subcontexts = ntuple(length(registered_keys)) do i
        algo_name = registered_keys[i]
        SubContext(algo_name, (;))
    end

    named_subcontexts = NamedTuple{registered_keys}(subcontexts)


    return ProcessContext(named_subcontexts, registry)
end

function ProcessContext(la::LA) where {LA<:LoopSpec}
    la = resolve(la)
    return _build_process_context(getregistry(la))
end
