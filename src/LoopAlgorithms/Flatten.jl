
function flat_funcs(la::LA) where {LA<:AbstractLoopAlgorithm}
    tree_flatten(la) do func
        if func isa StatefulAlgorithms.AbstractLoopAlgorithm
            return StatefulAlgorithms.getalgos(func)
        else
            return nothing
        end
    end
end

function flat_states(la::LA) where {LA<:AbstractLoopAlgorithm}
    tree_trait_flat_collect(la) do func
        if func isa StatefulAlgorithms.AbstractLoopAlgorithm
            return getalgos(func), getstates(func)
        else
            return nothing, nothing
        end
    end
end

function flat_multipliers(la::LA) where {LA<:AbstractLoopAlgorithm}
    @inline tree_trait_flatten(la, 1.) do func, multiplier
        if func isa StatefulAlgorithms.AbstractLoopAlgorithm
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
