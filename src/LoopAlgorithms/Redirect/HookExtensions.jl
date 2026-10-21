#=
How a `RedirectedVar` marker extends the base of reading and writing stored values (Context/View/Hooks.jl): the field
holding it is read and written at the location it points to.
=#

"""A redirected field is read at the location its marker points to."""
@inline read_value(reader::R, ::RedirectedVar{VL}) where {R<:AbstractContext, VL<:VarLocation} = ReadFrom{VL}()

"""A write to a redirected field goes on at the location its marker points to."""
@inline write_value(view::V, ::RedirectedVar{VL}, request::StoreInto) where {V<:SubContextView, VL<:VarLocation} =
    StoreInto{VL}(getfield(request, :value))
