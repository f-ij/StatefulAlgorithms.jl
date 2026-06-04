"""
Resolve multiple loop algorithms onto one shared registry.

Each loop algorithm is updated separately against that registry and returned in the
same order.
"""
function resolve(la1::LA1, la2::LA2, las::Vararg{AbstractLoopAlgorithm}) where {LA1<:AbstractLoopAlgorithm, LA2<:AbstractLoopAlgorithm}
    loopalgorithms = (la1, la2, las...)
    registry, keyed_loopalgorithms = _shared_registry_and_keyed_algos(loopalgorithms)
    return map(keyed_loopalgorithms) do resolved
        resolved = attach_registry_to_tree(resolved, registry)
        options = _unresolved_options(resolved)
        options isa Tuple || error("Resolving multiple loop algorithms together requires unresolved loop algorithms, but got $(typeof(resolved)) with options of type $(typeof(options)).")
        resolved = resolve_plan_wiring(resolved, registry)
        setoptions(resolved, _root_loop_options(options))
    end
end

"""Build one registry and keyed plan tree for several loop algorithms."""
function _shared_registry_and_keyed_algos(loopalgorithms::LAS) where {LAS<:Tuple}
    registry = NameSpaceRegistry()
    keyed_loopalgorithms = ()
    for la in loopalgorithms
        resolved = la isa LoopAlgorithm ? la : LoopAlgorithm(la)

        states = flat_states(resolved)
        multipliers = ntuple(i -> 1, length(states))
        registry = addall(registry, states, multipliers)

        registry, keyed_plan = add_algos_to_registry(registry, getplan(resolved), 1.0)
        keyed_loopalgorithms = (keyed_loopalgorithms..., setfield(resolved, :plan, keyed_plan))
    end
    return registry, keyed_loopalgorithms
end

@inline resolve(loopalgorithms::Tuple{Vararg{AbstractLoopAlgorithm}}) = resolve(loopalgorithms...)
