#=
`InteractiveVar`: mutable storage for a context value that external code changes while a process runs (made by the
`Interactive` input option, InputInterface/Interactive.jl). The hook extensions at the end are its methods of the base
of reading and writing stored values (Context/StoredValues/Hooks.jl).
=#

export InteractiveVar

"""
    InteractiveVar(x)

Mutable storage for an init-time interactive context variable.

Algorithms read the stored value through `SubContextView`, while external code
can mutate the value with `ref[] = value` without changing context shape.
"""
mutable struct InteractiveVar{T}
    x::T
end

"""Return the current value stored in an `InteractiveVar`."""
@inline Base.getindex(ref::InteractiveVar{T}) where {T} = getfield(ref, :x)::T

"""Update an `InteractiveVar`, preserving its original value type."""
@inline function Base.setindex!(ref::InteractiveVar{T}, value) where {T}
    setfield!(ref, :x, convert(T, value))
    return ref[]
end

##########################################
########## Hook extensions ###############
##########################################

"""An `InteractiveVar` reads as the value it currently holds."""
@inline read_value(reader::R, ref::InteractiveVar) where {R<:AbstractContext} = DirectRead(ref[])

"""A write to an `InteractiveVar` puts the value into its reference; nothing is merged."""
@inline function write_value(view::V, ref::InteractiveVar, request::StoreInto) where {V<:SubContextView}
    ref[] = getfield(request, :value)
    return NoWrite()
end
