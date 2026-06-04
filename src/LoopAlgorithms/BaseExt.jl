"""
Get the algorithm that matches in the LA tree
"""
function Base.getindex(ela::LA, key) where {LA<:AbstractLoopAlgorithm}
    _flat_funcs = flat_funcs(ela) 
    return staticmatch(_flat_funcs, Val(key))
end
