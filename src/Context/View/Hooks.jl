#=
The extendable base of how stored values are read and written: what a read of a stored value does (`read_action`),
which location a state field reads and writes back to (`_redirected_varlocation`), what a write stores
(`writeback_value`), and what the context after a run (`final_context`) shows (`shown_value`). The machinery that
follows `read_action`'s answers (`read_value`) is in Reading.jl.

Each function here has the default every stored value gets. A storage wrapper extends the hooks in a
`HookExtensions.jl` next to it: LoopAlgorithms/Redirect (`RedirectedVar`), LoopAlgorithms/Locals (`Maybe`,
`LocalProbe`), InputInterface (`InteractiveVar`).
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
