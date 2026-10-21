#=
The extendable base of how stored values are read and written: what a read of a stored value does (`read_value`),
what a write to a stored value does (`writeback_value`), and what the context after a run (`final_context`) shows
(`shown_value`). The hooks only answer with an action; the machinery that follows the answers is in Reading.jl
(`_follow_reads`) and Writing.jl (`_follow_writes`).

Each function here has the default every stored value gets. A storage wrapper extends the hooks in a
`HookExtensions.jl` next to it: LoopAlgorithms/Redirect (`RedirectedVar`), LoopAlgorithms/Locals (`Maybe`,
`LocalProbe`), InputInterface (`InteractiveVar`).
=#

##########################################
########## Reading a stored value ########
##########################################

"""
What `read_value` answers for a stored value: the value the read ends with (`DirectRead`), or where it goes on
(`ReadFrom`, `ReadVar`). `_follow_reads` follows the answers until one is a `DirectRead`.
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
    read_value(reader, stored) -> ReadAction

What reading the value `stored` in one field through `reader` does: `DirectRead(stored)` by default, so the reader
sees `stored`. A storage wrapper adds a method: a `RedirectedVar` answers `ReadFrom` (the field it points to), an
`InteractiveVar` `DirectRead(ref[])`, a declared local's `Maybe` `DirectRead` of its value. `reader` is the
`SubContextView` an algorithm reads through, or the `ProcessContext` of `context[Var(...)]` and `context.x`; it comes
first, as the container does in `getindex`.
"""
@inline read_value(reader::R, stored::S) where {R<:AbstractContext, S} = DirectRead(stored)

##########################################
########## Writing a stored value ########
##########################################

"""
What `writeback_value` answers for a write: where the write goes on (`StoreInto`), or how it ends (`DirectWrite`,
`NoWrite`). `_follow_writes` (Writing.jl) follows the answers until every one ends.
"""
abstract type WriteAction end

"""
    StoreInto{L}(value)

Write action: write `value` at location `L` (a `VarLocation` type). The value stored there is asked about in turn
(`writeback_value`). Every write starts as one; a redirect answers it with the location it points to.
"""
struct StoreInto{L, T} <: WriteAction
    value::T
end
@inline StoreInto{L}(value::T) where {L, T} = StoreInto{L, T}(value)

"""
    DirectWrite{L}(value)

Write action that ends the write: `value` is merged into the persistent context at location `L`. The default for every
stored value.
"""
struct DirectWrite{L, T} <: WriteAction
    value::T
end
@inline DirectWrite{L}(value::T) where {L, T} = DirectWrite{L, T}(value)

"""
    NoWrite()

Write action that ends the write with nothing merged: the hook has done the write itself (an `InteractiveVar` puts the
value into its reference).
"""
struct NoWrite <: WriteAction end

"""
    writeback_value(view, stored, request::StoreInto) -> WriteAction or a tuple of them

What writing `request`'s value through `view` to a field that holds `stored` does: `DirectWrite` at the request's
location by default, so the value is merged there. A storage wrapper adds a method: a `RedirectedVar` answers
`StoreInto` (the field it points to), an `InteractiveVar` puts the value into its reference and answers `NoWrite`.
"""
@inline writeback_value(view::V, stored::S, request::StoreInto{L}) where {V<:SubContextView, S, L} =
    DirectWrite{L}(getfield(request, :value))

##########################################
########## Showing a stored value ########
##########################################

"""
    shown_value(stored) -> value

The value the context after a run (`final_context`) shows for the value `stored`: `stored` itself by default. Unlike
`read_value` there is no reader and it never throws: a storage wrapper that may hold no value (a declared local's
`Maybe`) shows `nothing` then, and otherwise unwraps one layer and calls `shown_value(inner)` again.
"""
@inline shown_value(stored::S) where {S} = stored
