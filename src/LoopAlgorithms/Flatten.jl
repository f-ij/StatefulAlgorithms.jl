
function flat_funcs(la::LA) where {LA<:LoopSpec}
    tree_flatten(la) do func
        if func isa StatefulAlgorithms.LoopSpec
            return StatefulAlgorithms.getalgos(func)
        else
            return nothing
        end
    end
end

function flat_states(la::LA) where {LA<:LoopSpec}
    tree_trait_flat_collect(la) do func
        if func isa StatefulAlgorithms.LoopSpec
            return getalgos(func), getstates(func)
        else
            return nothing, nothing
        end
    end
end

function flat_multipliers(la::LA) where {LA<:LoopSpec}
    @inline tree_trait_flatten(la, 1.) do func, multiplier
        if func isa StatefulAlgorithms.LoopSpec
            return getalgos(func), multiplier .* StatefulAlgorithms.multipliers(func)
        else
            return nothing, nothing
        end
    end
end

flat_comp(t::Tuple) = flat_comp(t...)
flat_comp(a, b) = (a, b)
function flat_comp(ca::CompositeAlgorithm, interval)
    funcs = tree_flatten(ca) do func
        if func isa StatefulAlgorithms.CompositeAlgorithm
            return StatefulAlgorithms.getalgos(func)
        else
            return nothing
        end
    end

    intervals = tree_trait_flatten(ca, interval) do func, interval
        if func isa StatefulAlgorithms.CompositeAlgorithm
            return getalgos(func), interval .* StatefulAlgorithms.getschedule(func)
        else 
            return nothing, nothing
        end
    end
    return funcs, intervals
end

export states

"""
    states(la)

Every state of a resolved loop algorithm, flat: a `NamedTuple` from namespace to state, for example
`(_state_1 = GeneralState(a), _state_2 = GeneralState(a), _input = RuntimeInputState(...))`. Read from the registry, so a
state used by several blocks appears once, under the namespace it has in the context. Type stable.

Names are given by `resolve`, so a plan has to be resolved first: `states(resolve(plan))`.
"""
states(la::LoopAlgorithm) = _registry_states(getregistry(la))
states(fa::FinalizedAlgorithm) = states(inneralgorithm(fa))
states(::LoopSpec) = error("States are named when the plan is resolved; use `states(resolve(plan))`.")

"""The states among the algorithms of `reg` (handles wrapping an `AlgoState`), as namespace => state."""
@generated function _registry_states(reg::NameSpaceRegistry{E}) where {E}
    names = Symbol[]
    values = Any[]
    for (i, typeentry) in enumerate(E.parameters)
        for (j, handletype) in enumerate(getalgotypes(typeentry))
            handletype <: AbstractIdentifiableAlgo && algotype(handletype) <: AlgoState || continue
            push!(names, getkey(handletype))
            push!(values, :(getalgo(getalgos(getfield(getfield(reg, :entries), $i))[$j])))
        end
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end
