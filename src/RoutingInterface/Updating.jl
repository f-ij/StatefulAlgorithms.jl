"""
Update inherited routing options against a loop algorithm's current registry.

When a resolved child loop algorithm is composed into a parent, reuse the same
key-updating machinery for its plan-owned route/share options before carrying
them upward. `LoopAlgorithm` keeps runtime options on the wrapper, so resolved
children must read routing metadata from the wrapped plan tree rather than from
the wrapper's runtime option bucket.
"""
function update_option_keys(la::ALA) where {ALA<:AbstractLoopAlgorithm}
    options = la isa LoopAlgorithm ? _unresolved_options(la) : getoptions(la)
    options isa Tuple || return options
    isresolved(la) || return options
    routing_options = filter(option -> option isa Union{Route, Share}, options)
    return update_keys.(routing_options, Ref(getregistry(la)))
end
