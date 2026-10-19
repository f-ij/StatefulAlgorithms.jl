"""
    SimpleRegistry(algos, multipliers)

A registry without entry types: a flat tuple of keyed algorithms and their multipliers, found by matching each in
turn. Used for the few algorithms of a `Package`; a `NameSpaceRegistry` groups algorithms by entry type instead.
"""
struct SimpleRegistry{T} <: AbstractRegistry
    algos::T
    multipliers::Vector{Float64}
end
SimpleRegistry() = SimpleRegistry((), Float64[])

getalgos(r::SimpleRegistry) = getfield(r, :algos)
getmultipliers(r::SimpleRegistry) = getfield(r, :multipliers)
all_algos(r::SimpleRegistry) = getalgos(r)

Base.length(r::SimpleRegistry) = length(getalgos(r))
function getalgotypes(r::Union{SimpleRegistry{T}, Type{<:SimpleRegistry{T}}}) where T
    if isempty(T.parameters)
        return tuple()
    end
    tuple(T.parameters...)
end

static_findfirst_match(r::SR, val) where SR <: SimpleRegistry = static_findfirst_match(r, Val(val))
static_findfirst_match(r::SR, v::Val{val}) where {SR <: SimpleRegistry{T} where T,val} = static_findfirst_match(SR, v)

function Base.getindex(r::SimpleRegistry{T}, key) where T
    fidx = static_findfirst_match(r, Val(key))
    if isnothing(fidx)
        error("No match found for key: $key in registry of type $(typeof(r))")
    end
    return getalgos(r)[fidx]
end
function Base.getindex(r::SimpleRegistry{T}, idx::Int) where T
    return getalgos(r)[idx]
end

function add(r::SimpleRegistry{T}, obj, multiplier = 1.; withkey = nothing) where T
    fidx = static_findfirst_match(r, Val(obj))
    if isnothing(fidx)
        identifiable = Autokey(obj, length(getalgos(r)) + 1)
        newalgos = (getalgos(r)..., identifiable)
        push!(r.multipliers, multiplier)
        return setfield(r, :algos, newalgos), identifiable
    else
        multipliers = getmultipliers(r)
        multipliers[fidx] = multipliers[fidx] + multiplier
        return setfield(r, :multipliers, multipliers), getalgos(r)[fidx]
    end
end

@inline function static_get(r::Union{SR, Type{<:SR}}, key) where {SR <: SimpleRegistry}
    fidx = static_findfirst_match(SR, Val(key))
    if isnothing(fidx)
        error("No match found for key: $key in registry of type $(SR)")
    end
    return getalgotypes(SR)[fidx]
end

@inline function static_get_multiplier(r::SimpleRegistry, val)
    fidx = static_findfirst_match(r, Val(val))
    if isnothing(fidx)
        error("No match found for key: $val in registry of type $(typeof(r))")
    end
    return getmultipliers(r)[fidx]
end

