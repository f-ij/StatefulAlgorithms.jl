"""
Set up an empty `ProcessContext` from a resolved registry.

Route/share metadata is intentionally not embedded in `SubContext`; plan wiring
is supplied to `SubContextView` during `step!`.
"""
function _build_process_context(registry::R) where {R<:NameSpaceRegistry}
    @DebugMode "Creating ProcessContext with registry: $registry"

    # Create Subcontexts from registry
    registered_keys = all_keys(registry)
    @DebugMode "Registered names: $registered_keys"
    subcontexts = ntuple(length(registered_keys)) do i
        algo_name = registered_keys[i]
        SubContext(algo_name, (;))
    end

    named_subcontexts = NamedTuple{registered_keys}(subcontexts)

    @DebugMode "Created subcontexts: $named_subcontexts"

    return ProcessContext(named_subcontexts, registry)
end

function ProcessContext(la::LA) where {LA<:AbstractLoopAlgorithm}
    la = resolve(la)
    return _build_process_context(getregistry(la))
end
