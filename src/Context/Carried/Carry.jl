#=
EXPERIMENTAL: carrying a context through a loop as only the fields its steps write.

A loop that reassigns its whole context every step makes every field a loop variable. A field no step writes is
then a loop variable whose new value is its old one, which Julia keeps in a stack slot and copies every step. A
carrying loop never reassigns the context it started with and carries only the fields its steps can write:

    carried = create_carried(...the _step! arguments...)
    for ...
        stepped, runtimecontext = _step!(..., step_context(context, carried), ...)
        carried = next_carried(carried, stepped)
    end
    context = carried_context(context, carried)

How the written fields are found is hidden in `create_carried` (WriteTrace.jl). Every step gets the same type: the
starting context with the carried values, with an empty write trace. So the step is compiled once, and a loop inside
a step cannot see its context's type change between iterations.
=#

"""
    Carried{W}

What a loop carries from step to step: the current values of the persistent fields `W`, a tuple of
`(subcontext, field)` pairs, as `(; subcontext = (; field = value, ...), ...)`. `Carried{nothing}` holds the whole
context, for a step whose written fields could not be determined.
"""
struct Carried{W,V}
    values::V
end

@inline Carried{W}(values::V) where {W,V} = Carried{W,V}(values)

"""
    create_carried(algo, cursor, context, runtimecontext, wiring, namespace, process, lifetime)

What a loop that runs `_step!` with these arguments carries before its first step: the values in `context` of the
fields the step can write (`Carried{nothing}` with the whole context when those are not known).
"""
@inline function create_carried(algo::A, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N,
                                process::P, lifetime::LT) where {A,S,C<:ProcessContext,RC,W,N,P,LT}
    return @inline _carried(context, _written_fields(algo, cursor, context, runtimecontext, wiring, namespace, process, lifetime))
end

# Another kind of context (not a `ProcessContext`) is never traced: carry it whole.
@inline create_carried(algo::A, cursor::S, context::C, args::Vararg{Any,5}) where {A,S,C} = Carried{nothing}(context)

@inline _carried(context::C, ::Nothing) where {C<:ProcessContext} = Carried{nothing}(context)
@inline _carried(context::C, ::Val{W}) where {C<:ProcessContext,W} = Carried{W}(@inline _written_values(context, Val(W)))

"""The context a step gets: `context` with the carried values, with an empty write trace (or the carried context)."""
@inline step_context(::C, carried::Carried{nothing}) where {C} = getfield(carried, :values)
@inline step_context(context::C, carried::Carried) where {C} =
    @inline with_empty_trace(@inline merge_into_subcontexts(without_trace(context), getfield(carried, :values)))

"""What a loop carries after a step that returned `stepped`: the new values of the same fields."""
@inline next_carried(::Carried{nothing}, stepped::C) where {C} = Carried{nothing}(stepped)
@inline next_carried(::Carried{W}, stepped::C) where {W,C} = Carried{W}(@inline _written_values(stepped, Val(W)))

"""
The whole context: `context` with the carried values (or the carried context). A traced `context` traces the
carried fields as written, so an enclosing step's write trace sees what this loop wrote.
"""
@inline carried_context(::C, carried::Carried{nothing}) where {C} = getfield(carried, :values)
@inline carried_context(context::C, carried::Carried) where {C} =
    @inline merge_into_subcontexts(context, getfield(carried, :values))

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
