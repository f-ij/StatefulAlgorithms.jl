#=
EXPERIMENTAL: carrying a context through a loop as only the fields its steps write.

A loop that reassigns its whole context every step makes every field a loop variable. A field no step writes is
then a loop variable whose new value is its old one, which Julia keeps in a stack slot and copies every step. A
carrying loop keeps the context it started with (`base`, never reassigned) and carries only `delta`, the fields its
steps can write (`_written_fields`, WriteLog.jl):

    written = _written_fields(...the _step! arguments...)
    carried = loop_carry(context, written)
    for ...
        stepped, runtimecontext = _step!(..., step_context(context, carried, written), ...)
        carried = next_carry(stepped, written)
    end
    context = carried_context(context, carried, written)

Every step gets the same type: `base` merged with `delta`, with an empty write log. So the step is compiled once,
for the type `_written_fields` asked about, and a loop inside a step cannot see its context's type change between
iterations. With `written === nothing` (not determined) the functions carry the whole context, as without them.
=#

"""What a loop carries from step to step: the written fields of `context`, or all of `context`."""
@inline loop_carry(context::C, ::Nothing) where {C<:ProcessContext} = context
@inline loop_carry(context::C, written::Val) where {C<:ProcessContext} = @inline _written_values(context, written)

"""The context a step gets: `base` with the carried fields, with an empty write log (or the carried context)."""
@inline step_context(base::C, carried::CC, ::Nothing) where {C,CC} = carried
@inline step_context(base::C, delta::D, ::Val) where {C<:ProcessContext,D<:NamedTuple} =
    @inline with_empty_log(@inline merge_into_subcontexts(without_log(base), delta))

"""What a loop carries after a step that returned `stepped`."""
@inline next_carry(stepped::C, ::Nothing) where {C<:ProcessContext} = stepped
@inline next_carry(stepped::C, written::Val) where {C<:ProcessContext} = @inline _written_values(stepped, written)

"""
The whole context: `base` with the carried fields (or the carried context). A logged `base` logs the carried fields
as written, so an enclosing step's write log sees what this loop wrote.
"""
@inline carried_context(base::C, carried::CC, ::Nothing) where {C,CC} = carried
@inline carried_context(base::C, delta::D, ::Val) where {C<:ProcessContext,D<:NamedTuple} =
    @inline merge_into_subcontexts(base, delta)

"""
    _written_values(context, Val(W))

The values of the fields `W` in `context`, as `(; subcontext = (; field = value, ...), ...)`: the shape
`merge_into_subcontexts` takes.
"""
@inline @generated function _written_values(context::ProcessContext, ::Val{W}) where {W}
    subs = Tuple(unique(first.(W)))
    entries = map(subs) do s
        fields = Tuple(f for (s2, f) in W if s2 === s)
        values = [:(getfield(getdata(getfield(subcontexts, $(QuoteNode(s)))), $(QuoteNode(f)))) for f in fields]
        :(NamedTuple{$fields}(($(values...),)))
    end
    return quote
        subcontexts = @inline get_subcontexts(context)
        return NamedTuple{$subs}(($(entries...),))
    end
end
