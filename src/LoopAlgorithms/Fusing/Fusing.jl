export fuse, isfused

include("ContextExt.jl")

function flatten_comp_funcs(funcs, _intervals, stop_at_options = true)
    flat_funcs, flat_intervals = flat_tree_property_recursion(funcs, _intervals) do el, trait
        if !iscomposite(el) || (stop_at_options && !isempty(getoptions(el)))
            return nothing, nothing
        end
        newels = getalgos(el)
        newtraits = intervals(el)
        multiplied_newtraits = map(x -> x*trait, newtraits)
        return newels, multiplied_newtraits
        # return newels, trait.*newtraits

    end
    return flat_funcs, flat_intervals
end

"""
Deconstruct a `CompositeAlgorithm` into its leaf child algorithms and intervals.

This is the public "old flatten" behavior: route/share options do not make the
composite opaque here. Constructor parsing uses `flatten_comp_funcs` instead so
nested composites with local plan metadata are not flattened accidentally.
"""
function flatten(comp::CompositeAlgorithm)
    # `false` keeps the old public flatten behavior: options do not stop descent.
    return flatten_comp_funcs((comp,), (1,), false)
end

function flatten(comp::LoopAlgorithm{<:CompositeAlgorithm})
    return flatten(getplan(comp))
end

function flatten_loopalgorithms(la::ALA) where {ALA<:AbstractLoopAlgorithm}
    flat_funcs, flat_intervals = flat_tree_property_recursion((la,), (1,)) do el, trait
        if !(el isa AbstractLoopAlgorithm)
            return nothing, nothing
        end
        newels = getalgos(el)
        newtraits = multipliers(el)
        return newels, trait.*newtraits
    end
    return flat_funcs, flat_intervals
end


function fuse(cla::ALA, name_prefix = "") where {ALA<:AbstractLoopAlgorithm}
    if isfused(cla)
        return cla
    end

    flat_funcs, flat_intervals = flatten(cla)

    return CompositeAlgorithm(flat_funcs, flat_intervals)
end
