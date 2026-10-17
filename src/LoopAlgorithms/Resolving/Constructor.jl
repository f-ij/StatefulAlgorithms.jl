"""
Resolve multiple loop algorithms onto one shared registry.

Each loop algorithm is updated separately against that registry and returned in the
same order.
"""
function resolve(la1::LA1, la2::LA2, las::Vararg{LoopSpec}) where {LA1<:LoopSpec, LA2<:LoopSpec}
    loopalgorithms = (la1, la2, las...)
    registry, keyed_loopalgorithms = _shared_registry_and_keyed_algos(loopalgorithms)
    return map(keyed_loopalgorithms) do resolved
        resolved = _attach_registry(resolved, registry)
        resolved = resolve_plan_wiring(resolved, registry)
        setoptions(resolved, _root_options(resolved))
    end
end

"""Build one registry and keyed plan tree for several loop algorithms."""
# TODO: a `FinalizedAlgorithm` argument fails here (`LoopAlgorithm(::FinalizedAlgorithm)` has no method), and unlike
# `resolve(la)` this skips the `isresolved` check and `Unique` id normalization.
function _shared_registry_and_keyed_algos(loopalgorithms::LAS) where {LAS<:Tuple}
    registry = NameSpaceRegistry()
    keyed_loopalgorithms = ()
    for la in loopalgorithms
        resolved = la isa LoopAlgorithm ? la : LoopAlgorithm(la)
        registry, keyed = setup_registry_and_keyed_algos(resolved, registry)
        keyed_loopalgorithms = (keyed_loopalgorithms..., keyed)
    end
    return registry, keyed_loopalgorithms
end

@inline resolve(loopalgorithms::Tuple{Vararg{LoopSpec}}) = resolve(loopalgorithms...)
