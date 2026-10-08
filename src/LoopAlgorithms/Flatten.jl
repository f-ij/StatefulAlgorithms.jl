
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
            return getalgos(func), interval .* StatefulAlgorithms.intervals(func)
        else 
            return nothing, nothing
        end
    end
    return funcs, intervals
end

export allstates

"""
    allstates(la)

Every state of a resolved loop algorithm, flat: a `NamedTuple` from namespace to state, for example
`(_state_1 = GeneralState(a), _state_2 = GeneralState(a), _input = RuntimeInputState(...))`. Read from the registry, so a
state used by several blocks appears once, under the namespace it has in the context. Type stable.

Names are given by `resolve`, so a plan has to be resolved first: `allstates(resolve(plan))`.
"""
allstates(la::LoopAlgorithm) = _registry_states(getregistry(la))
allstates(fa::FinalizedAlgorithm) = allstates(inneralgorithm(fa))
allstates(::LoopSpec) = error("States are named when the plan is resolved; use `allstates(resolve(plan))`.")

"""The states among the entries of `reg` (entries wrapping a `ProcessState`), as namespace => state."""
@generated function _registry_states(reg::NameSpaceRegistry{E}) where {E}
    names = Symbol[]
    values = Any[]
    for (i, typeentry) in enumerate(E.parameters)
        entrytypes = fieldtype(typeentry, :entries).parameters
        for (j, entry) in enumerate(entrytypes)
            entry <: AbstractIdentifiableAlgo && algotype(entry) <: ProcessState || continue
            push!(names, getkey(entry))
            push!(values, :(getalgo(getfield(getfield(getfield(reg, :entries), $i), :entries)[$j])))
        end
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end
