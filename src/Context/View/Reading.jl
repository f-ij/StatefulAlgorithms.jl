#=
Reading a stored value: ask the hook `read_value` (Hooks.jl) what reading it does, and follow its answers until one
ends the read (`DirectRead`).
=#

"""
    _follow_reads(reader, stored)

Return the value `reader` sees for the value `stored` in one of its fields: the hook `read_value(reader, stored)` is
asked, and its answers are followed until one is a `DirectRead`.
"""
@inline _follow_reads(reader::R, stored::S) where {R<:AbstractContext, S} =
    @inline _follow_read(reader, read_value(reader, stored))

@inline _follow_read(reader::R, action::DirectRead{T}) where {R<:AbstractContext, T} = getfield(action, :value)

# The value stored at `L` is asked about in turn, so a redirect to a redirect is followed as well.
@inline _follow_read(reader::R, ::ReadFrom{L}) where {R<:AbstractContext, L} = @inline _follow_reads(reader, (@inline stored_value_at(reader, L())))

# Unused API for now (see `ReadVar`): no wrapper in the package answers it.
@inline _follow_read(reader::R, action::ReadVar{T}) where {R<:AbstractContext, T} =
    @inline _follow_reads(reader, getfield(action, :value))

"""
    stored_value_at(reader, location)

Return the value stored at the state location `location` (a `VarLocation{:state}`), as it is stored: no hook is asked
about it. What a `ReadFrom` and a `StoreInto` go on with. A view reads it with `partition_storedproperty`, a
`ProcessContext` from its subcontext.
"""
function stored_value_at end
