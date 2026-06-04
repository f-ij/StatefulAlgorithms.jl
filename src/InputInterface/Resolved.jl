"""
Return whether an init input or override carries a concrete registry namespace.

Resolved lifecycle specs carry the registry key as their target type parameter.
Targetless `Init(; ...)` is an all-target input and still needs registry
expansion before it can be merged into a concrete process context.
"""
@inline isresolved(::Union{Init{Target}, Type{<:Init{Target}}}) where {Target} =
    Target isa Symbol
@inline isresolved(::Union{Override{Target}, Type{<:Override{Target}}}) where {Target} = Target isa Symbol
@inline isresolved(::Union{Interactive{Target}, Type{<:Interactive{Target}}}) where {Target} = Target isa Symbol

"""
Return whether an init input should be expanded to every registered namespace.
"""
@inline isalltargets(::Union{Init{Target}, Type{<:Init{Target}}}) where {Target} =
    Target === AllInitTargets
@inline isalltargets(::Union{Override, Type{<:Override}}) = false
@inline isalltargets(::Union{Interactive, Type{<:Interactive}}) = false
