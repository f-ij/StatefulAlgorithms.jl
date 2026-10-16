#=
Reading a stored value: ask `read_action` (Interface.jl) about it and follow its answers until one ends the read.
=#

"""
    read_value(reader, stored)

Return the value `reader` sees for the value `stored` in one of its fields: `read_action(reader, stored)` followed
until it answers `DirectRead`.
"""
@inline read_value(reader::R, stored::S) where {R<:AbstractContext, S} =
    @inline _follow_read(reader, read_action(reader, stored))

@inline _follow_read(reader::R, action::DirectRead{T}) where {R<:AbstractContext, T} = getfield(action, :value)

# `read_location` reads the field and ends in `read_value` itself, so a redirect to a redirect is followed as well.
@inline _follow_read(reader::R, ::ReadFrom{L}) where {R<:AbstractContext, L} = @inline read_location(reader, L())

# Unused API for now (see `ReadVar`): no wrapper in the package answers it.
@inline _follow_read(reader::R, action::ReadVar{T}) where {R<:AbstractContext, T} =
    @inline read_value(reader, getfield(action, :value))

"""
    read_location(reader, location)

Return the value `reader` sees at `location` (a `VarLocation`): what a `ReadFrom` goes on with. A view reads it as an
algorithm would (`getproperty(view, location)`), a `ProcessContext` as `context[Var(...)]`.
"""
function read_location end
