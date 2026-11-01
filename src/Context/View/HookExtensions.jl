#=
Extensions of the hook `context_partition` (Context/Hooks.jl) for a view's locations.
=#

"""The partition a `VarLocation` in a run's context is stored in."""
@inline context_partition(vl::Union{VarLocation{P}, Type{<:VarLocation{P}}}) where {P<:Partition} = P()
