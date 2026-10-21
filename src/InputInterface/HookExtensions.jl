#=
How an `InteractiveVar` extends the base of reading and writing stored values (Context/View/Hooks.jl): it reads as
the value it holds and absorbs writes into its reference, keeping its place in the context.
=#

"""An `InteractiveVar` reads as the value it currently holds."""
@inline read_action(reader::R, ref::InteractiveVar) where {R<:AbstractContext} = DirectRead(ref[])

"""Write an algorithm return value through an existing `InteractiveVar`."""
@inline function writeback_value(ref::InteractiveVar, value)
    ref[] = value
    return ref
end
