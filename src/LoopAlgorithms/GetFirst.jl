unwrap_cla(cla::LA) where {LA<:AbstractLoopAlgorithm} = getalgos(cla)
unwrap_cla(x) = x

# Empty tuple
@inline getfirst_node(f, ::Tuple{}; unwrap = identity) = nothing

# Tuple case (destructure head + tail at compile time)
"""
Destructure nested structures, where the nodes and leaves can match a predicate f.
    To get the connected nodes, use unwrap
"""
@inline function getfirst_node(f, coll; unwrap = identity)
    if coll isa Tuple
        frst = getfirst_node(f, gethead(coll); unwrap)
        if !isnothing(frst)
            return frst
        end
        return getfirst_node(f, gettail(coll); unwrap)
    elseif f(coll)
            return coll
    else
        # Not a tuple, so unwrap and try again
        unwrapped_coll = unwrap(coll)
        if unwrapped_coll == coll # Not a tuple and cannot be unwrapped, so didn't pass
            return nothing
        else # Was unwrapped, so try again
            return getfirst_node(f, unwrapped_coll; unwrap)   
        end 
    end
end
