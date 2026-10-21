#=
How a `RedirectedVar` marker extends the base of reading and writing stored values (Context/View/Hooks.jl): the field
holding it reads and writes back at the location it points to.
=#

"""A redirected state field is read and written back at the location its marker points to."""
@inline _redirected_varlocation(::Type{T}, ::Val{SubKey}, ::Val{name}) where {VL<:VarLocation, T<:RedirectedVar{VL}, SubKey, name} =
    VL()

"""A redirected field is read at the location its marker points to."""
@inline read_action(reader::R, ::RedirectedVar{VL}) where {R<:AbstractContext, VL<:VarLocation} = ReadFrom{VL}()
