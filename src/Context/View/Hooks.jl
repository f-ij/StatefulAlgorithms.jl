#=
Extendable API of views: functions packages overload to change what a read or a write of a stored value does, and
what the context after a run (`final_context`) shows for it.
=#

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
