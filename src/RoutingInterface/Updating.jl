"""
Return the route/share wiring of a loop algorithm's plan tree, with keys updated against its registry.

When a resolved child loop algorithm is composed into a parent, its wiring is
carried upward with keys that match the registry it was resolved with. The
wiring is read from the plans (`wiring_values`), not from the options.
"""
function update_option_keys(la::ALA) where {ALA<:AbstractLoopAlgorithm}
    wiring = _tree_wiring_values(la)
    isresolved(la) || return wiring
    routing = filter(option -> option isa Union{Route, Share}, wiring)
    return update_keys.(routing, Ref(getregistry(la)))
end
