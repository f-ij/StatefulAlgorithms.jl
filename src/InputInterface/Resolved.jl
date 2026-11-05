"""
Return whether an init input or override carries a concrete registry namespace.

Resolved lifecycle specs carry the registry key as their target type parameter.
`InitArgs(ToAll(); ...)` still needs registry expansion before it can be merged
into a concrete process context. An `Only` is resolved when its type parameter
holds the tuple of registry keys.
"""
@inline isresolved(::Union{InitArgs{Target}, Type{<:InitArgs{Target}}}) where {Target} =
    Target isa Symbol
@inline isresolved(::Union{Override{Target}, Type{<:Override{Target}}}) where {Target} = Target isa Symbol
@inline isresolved(::Union{Interactive{Target}, Type{<:Interactive{Target}}}) where {Target} = Target isa Symbol
@inline isresolved(::Union{Only{Targets}, Type{<:Only{Targets}}}) where {Targets} = Targets isa Tuple

"""Whether an `InitArgs` goes to every registered namespace (its target is `ToAll()`)."""
@inline _is_to_all_ns(::Union{InitArgs{Target}, Type{<:InitArgs{Target}}}) where {Target} = Target isa ToAll
@inline _is_to_all_ns(::Union{InputInterface, Type{<:InputInterface}}) = false
