#=
The extendable base of how stored values are read and written: what a read of a stored value shows (`read_action`,
followed by `read_value`), which location a state field reads and writes back to (`_redirected_varlocation`), what a
write stores (`writeback_value`), and what the context after a run (`final_context`) shows (`shown_value`).

Each function here has the default every stored value gets. A storage wrapper extends it with methods in a file of
its own, next to the wrapper: `RedirectedVar` in LoopAlgorithms/Redirect/Hooks.jl.
=#

##########################################
########## Reading a stored value ########
##########################################

"""
What `read_action` answers for a stored value: the value the read ends with (`DirectRead`), or where it goes on
(`ReadFrom`, `ReadVar`). `read_value` follows the answers until one is a `DirectRead`.
"""
abstract type ReadAction end

"""
    ReadFrom{L}()

Read action: the read goes on at location `L` (a `VarLocation` type): the value stored there is read and asked about
in turn. A redirect answers this.
"""
struct ReadFrom{L} <: ReadAction end

"""
    DirectRead(value)

Read action that ends the read: the reader sees `value`. The default for every stored value.
"""
struct DirectRead{T} <: ReadAction
    value::T
end

"""
    ReadVar(inner)

Read action: the read goes on with `inner`, the stored value with one wrapper layer removed, which is asked about in
turn. Unused API for now: no wrapper in the package holds another wrapper, so every package method answers
`DirectRead` or `ReadFrom`; only the tests use it.
"""
struct ReadVar{T} <: ReadAction
    value::T
end

"""
    read_action(reader, stored) -> ReadAction

What reading the value `stored` in one field through `reader` does: `DirectRead(stored)` by default, so the reader
sees `stored`. A storage wrapper adds a method: a `RedirectedVar` answers `ReadFrom` (the field it points to), an
`InteractiveVar` `DirectRead(ref[])`, a declared local's `Maybe` `DirectRead` of its value. `reader` is the
`SubContextView` an algorithm reads through, or the `ProcessContext` of `context[Var(...)]` and `context.x`; it comes
first, as the container does in `getindex`.
"""
@inline read_action(reader::R, stored::S) where {R<:AbstractContext, S} = DirectRead(stored)

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

##########################################
########## Where a state field is stored #
##########################################

"""
    _redirected_varlocation(::Type{T}, Val(subcontext), Val(name))

Return the location a view reads and writes back to for the state field `subcontext.name`, whose stored value has
type `T`: that field itself by default. A storage marker type adds a method to send reads and writeback to another
`VarLocation`; `RedirectedVar` makes the field behave as the source field it points to.
"""
@inline _redirected_varlocation(::Type{T}, ::Val{SubKey}, ::Val{name}) where {T, SubKey, name} =
    VarLocation{:state}(SubKey, name)

##########################################
########## Writing and showing ###########
##########################################

"""
    writeback_value(stored, returned) -> value

The value to store in a field that holds `stored` when a step returns `returned` for it: `returned` by default. A
storage wrapper that absorbs writes while keeping its place in the context adds a method (an `InteractiveVar` puts
`returned` into its reference and stays itself).
"""
@inline writeback_value(stored::S, returned::R) where {S, R} = returned

"""
    shown_value(stored) -> value

The value the context after a run (`final_context`) shows for the value `stored`: `stored` itself by default. Unlike
`read_action` there is no reader and it never throws: a storage wrapper that may hold no value (a declared local's
`Maybe`) shows `nothing` then, and otherwise unwraps one layer and calls `shown_value(inner)` again.
"""
@inline shown_value(stored::S) where {S} = stored
