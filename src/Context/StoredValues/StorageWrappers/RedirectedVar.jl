#=
`RedirectedVar`: the marker `Redirect` writes into a state field (LoopAlgorithms/Redirect/Materialization.jl), so the
field is read and written at the location it points to. The hook extensions at the end are its methods of the base of
reading and writing stored values (Context/StoredValues/Hooks.jl).
=#

"""
    RedirectedVar(varlocation)

Persistent context marker for a state field whose algorithm-facing value is
backed by another `VarLocation`.
"""
struct RedirectedVar{T<:VarLocation}
    varlocation::T
end

##########################################
########## Hook extensions ###############
##########################################

"""A redirected field is read at the location its marker points to."""
@inline read_value(reader::R, ::RedirectedVar{VL}) where {R<:AbstractContext, VL<:VarLocation} = ReadFrom{VL}()

"""A write to a redirected field goes on at the location its marker points to."""
@inline write_value(view::V, ::RedirectedVar{VL}, request::StoreInto) where {V<:SubContextView, VL<:VarLocation} =
    StoreInto{VL}(getfield(request, :value))
