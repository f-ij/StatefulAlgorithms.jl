#=
How an `InteractiveVar` extends the base of reading and writing stored values (Context/View/Hooks.jl): it reads as
the value it holds, and a write puts the value into its reference, so nothing is merged and it keeps its place.
=#

"""An `InteractiveVar` reads as the value it currently holds."""
@inline read_value(reader::R, ref::InteractiveVar) where {R<:AbstractContext} = DirectRead(ref[])

"""A write to an `InteractiveVar` puts the value into its reference; nothing is merged."""
@inline function writeback_value(view::V, ref::InteractiveVar, request::StoreInto) where {V<:SubContextView}
    ref[] = getfield(request, :value)
    return NoWrite()
end
