#=
How a field's stored value is read and written when what is stored is not the value itself. Some fields hold a wrapper
instead of a plain value: a `RedirectedVar` (the field lives at another location, set up by `Redirect`), an
`InteractiveVar` (the value lives in a `Ref` a user can change while the loop runs), a declared local's `Maybe` (a
local that may not have been assigned yet). A read must see the value behind the wrapper, and a write must reach it.

Instead of a special case per wrapper in the view, each wrapper type adds a method to a hook here: `read_value` for
reads, `write_value` for writes, `shown_value` for the context after a run. A hook does not read or write itself: it
answers with an action, either "done, here is the value" or "go on there". The code that follows the answers
(ReadingWriting.jl: `_follow_reads`, `_follow_writes`) does the recursion. That keeps every hook one step, and it is
what makes chains work, e.g. a redirect pointing to a field that is itself redirected or interactive.

Each wrapper has its own file in StorageWrappers/ next to this file, with its struct and its methods of these hooks at
the end: `RedirectedVar.jl`, `Maybe.jl`, `InteractiveVar.jl`.
=#

##########################################
########## Reading a stored value ########
##########################################

"""
An answer of `read_value`: either the read is done (`DirectRead`), or it goes on at another location (`ReadFrom`) or
with an unwrapped value (`ReadVar`). `_follow_reads` asks `read_value` again on every "go on" answer until it gets a
`DirectRead`.
"""
abstract type ReadAction end

"""
    ReadFrom{L}()

"Read at location `L` instead" (`L` a `VarLocation` type). Written for redirects: a field holding a `RedirectedVar`
has no value of its own, it stands for another field. The value stored at `L` is fetched (`getproperty_raw`) and
`read_value` is asked about it in turn, so a redirect to a field that is itself redirected or wrapped is followed too.
Only `RedirectedVar` answers this.
"""
struct ReadFrom{L} <: ReadAction end

"""
    DirectRead(value)

"Done: the reader sees `value`." The answer that ends every read. The default for a plain value (it reads as itself);
a wrapper answers it with the value behind it (`InteractiveVar`: `ref[]`; a declared local's `Maybe`: its value).
"""
struct DirectRead{T} <: ReadAction
    value::T
end

"""
    ReadVar(inner)

"Go on with `inner`": the stored value with one wrapper removed, asked about again with `read_value`. Written for a
wrapper that holds another wrapper: `DirectRead` would end the read on the inner wrapper itself instead of the value
behind it. No wrapper in the package nests today (an `InteractiveVar` never holds a redirect, a `Maybe` only holds what
a step returned), so nothing in `src/` answers it. It was kept on purpose (2026-10-16) as API for such a wrapper; the
test wrapper `RecursiveViewWrapper` (test/RedirectTest.jl) nests itself to keep it working.
"""
struct ReadVar{T} <: ReadAction
    value::T
end

"""
    read_value(reader, stored) -> ReadAction

The hook a storage wrapper extends to say what reading it gives: `DirectRead(stored)` by default, so a plain value
reads as itself. `RedirectedVar` answers `ReadFrom` (the field it points to), `InteractiveVar` `DirectRead(ref[])`, a
declared local's `Maybe` `DirectRead` of its value. `reader` is the `SubContextView` an algorithm reads through, or the
`ProcessContext` of `context[Var(...)]` and `context.x`; it comes first, as the container does in `getindex`.
"""
@inline read_value(reader::R, stored::S) where {R<:AbstractContext, S} = DirectRead(stored)

##########################################
########## Writing a stored value ########
##########################################

"""
An answer of `write_value`: either the write is done (`DirectWrite`: merge this value at this location; `NoWrite`:
nothing to merge), or it goes on at another location (`StoreInto`). A hook may answer a tuple of actions;
`_follow_writes` keeps asking until every one is done, and the `DirectWrite`s left are merged into the context.
"""
abstract type WriteAction end

"""
    StoreInto{L}(value)

"Write `value` at location `L`" (`L` a `VarLocation` type). Every write an algorithm makes starts as one (one per field
after a reverse transform), and `write_value` is asked what writing to the value stored at `L` does. A redirect answers
another `StoreInto` with the location it points to, so the write lands where the value really lives.
"""
struct StoreInto{L, T} <: WriteAction
    value::T
end
@inline StoreInto{L}(value::T) where {L, T} = StoreInto{L, T}(value)

"""
    DirectWrite{L}(value)

"Done: merge `value` into the context at location `L`." The default answer, for a field that holds a plain value.
"""
struct DirectWrite{L, T} <: WriteAction
    value::T
end
@inline DirectWrite{L}(value::T) where {L, T} = DirectWrite{L, T}(value)

"""
    NoWrite()

"Done, nothing to merge." Written for `InteractiveVar`: its value lives in a `Ref`, so the hook puts the value into the
`Ref` itself; merging would only write the same wrapper back over itself.
"""
struct NoWrite <: WriteAction end

"""
    write_value(view, stored, request::StoreInto) -> WriteAction or a tuple of them

The hook a storage wrapper extends to say what writing to it does: `DirectWrite` at the request's location by default,
so the value is merged there. `RedirectedVar` answers `StoreInto` (the field it points to), `InteractiveVar` puts the
value into its `Ref` and answers `NoWrite`.
"""
@inline write_value(view::V, stored::S, request::StoreInto{L}) where {V<:SubContextView, S, L} =
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
