export fuse, isfused

include("ContextExt.jl")

"""
Return `true` when the nested composite `el` is dissolved into its parent by flattening: always without
`stop_at_options`, and with it only when neither `el` nor the plan it wraps carries options or route/share wiring.
"""
Base.@nospecializeinfer function _flattens_into_parent(@nospecialize(el), stop_at_options::Bool)
    el isa LoopSpec && iscomposite(el) || return false
    stop_at_options || return true
    isempty(getoptions(el)) || return false
    return !(el isa LoopAlgorithm) || isempty(getoptions(getplan(el)))
end

"""
Replace every nested `CompositeAlgorithm` in `funcs` by its children, in place and recursively, multiplying the
children's intervals by the parent's interval. With `stop_at_options`, a composite that carries route/share options
is kept whole.

Runs on untyped values in a loop: the input is only known at run time, and a typed tuple recursion here compiled
again for every plan type (and made Julia's compiler crash with "irinterp is unable to handle heavy recursion").
"""
Base.@nospecializeinfer function flatten_comp_funcs(@nospecialize(funcs::Tuple), @nospecialize(_intervals::Tuple), stop_at_options::Bool = true)
    flat_funcs = Any[]
    flat_intervals = Any[]
    _flatten_comp_funcs!(flat_funcs, flat_intervals, funcs, _intervals, stop_at_options)
    return Tuple(flat_funcs), Tuple(flat_intervals)
end

Base.@nospecializeinfer function _flatten_comp_funcs!(flat_funcs::Vector{Any}, flat_intervals::Vector{Any}, @nospecialize(funcs::Tuple), @nospecialize(_intervals::Tuple), stop_at_options::Bool)
    for i in eachindex(funcs)
        el = funcs[i]
        trait = _intervals[i]
        # `el isa LoopSpec` first: `iscomposite(el)` on any other value would compile once per value type.
        if _flattens_into_parent(el, stop_at_options)
            child_intervals = intervals(el)
            multiplied = Any[child_intervals[j] * trait for j in eachindex(child_intervals)]
            _flatten_comp_funcs!(flat_funcs, flat_intervals, getalgos(el), Tuple(multiplied), stop_at_options)
        else
            push!(flat_funcs, el)
            push!(flat_intervals, trait)
        end
    end
    return nothing
end

"""
    flattened_states(funcs::Tuple, stop_at_options = true)

The states of the nested composites `flatten_comp_funcs` dissolves into their parent, so the parent can keep them:
a block's `@state` lives on its wrapper, which flattening drops.
"""
Base.@nospecializeinfer function flattened_states(@nospecialize(funcs::Tuple), stop_at_options::Bool = true)
    states = Any[]
    _flattened_states!(states, funcs, stop_at_options)
    return Tuple(states)
end

Base.@nospecializeinfer function _flattened_states!(states::Vector{Any}, @nospecialize(funcs::Tuple), stop_at_options::Bool)
    for el in funcs
        if _flattens_into_parent(el, stop_at_options)
            append!(states, getstates(el))
            _flattened_states!(states, getalgos(el), stop_at_options)
        end
    end
    return nothing
end

"""
    flatten_comp_funcs_typed(funcs::Tuple, intervals::Tuple, stop_at_options = true)

Typed version of `flatten_comp_funcs`, with the same result: the children with every nested `CompositeAlgorithm`
replaced by its own children (intervals multiplied), keeping composites with route/share options whole when
`stop_at_options`. Written as typed tuple recursion (`flat_tree_property_recursion`), so the result type is known to
the compiler when the input types are.

Not used. It is compiled again for every plan type, which includes every new `Unique` handle, and for larger plans
Julia's compiler fails while inferring it ("irinterp is unable to handle heavy recursion correctly"): the call still
works, but that compile time is wasted and repeated on the next run. Kept for a typed construction path; a front
recursion like `_add_algo_tuple_in_order` would avoid the compiler failure.
"""
function flatten_comp_funcs_typed(funcs, _intervals, stop_at_options = true)
    flat_funcs, flat_intervals = flat_tree_property_recursion(funcs, _intervals) do el, trait
        if !_flattens_into_parent(el, stop_at_options)
            return nothing, nothing
        end
        newels = getalgos(el)
        newtraits = intervals(el)
        multiplied_newtraits = map(x -> x*trait, newtraits)
        return newels, multiplied_newtraits
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

function flatten_loopalgorithms(la::ALA) where {ALA<:LoopSpec}
    flat_funcs, flat_intervals = flat_tree_property_recursion((la,), (1,)) do el, trait
        if !(el isa LoopSpec)
            return nothing, nothing
        end
        newels = getalgos(el)
        newtraits = multipliers(el)
        return newels, trait.*newtraits
    end
    return flat_funcs, flat_intervals
end


function fuse(cla::ALA, name_prefix = "") where {ALA<:LoopSpec}
    if isfused(cla)
        return cla
    end

    flat_funcs, flat_intervals = flatten(cla)

    return CompositeAlgorithm(flat_funcs, flat_intervals)
end
