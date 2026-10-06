#=
Carrying a context through a loop as only the fields its steps write.

Why: a loop that reassigns its whole context every step makes every field a loop variable. A field no step writes
is then a loop variable whose new value is its old one. For a context that holds both pointers and plain values,
Julia keeps such a variable in a stack slot and copies it every step, and the compiler cannot keep the context in
registers (the InteractiveIsing 3D graph example copied 600 + 624 bytes per step and ran at 206 updates/s/spin;
carrying only the written fields: 509). A carrying loop never reassigns the context it started with: the fields no
step writes are read from where they already are, and only the fields its steps can write cross from one step to
the next:

    carried = create_carried(...the _step! arguments...)
    for ...
        stepped, runtimecontext = _step!(..., carried_context(context, carried), ...)
        carried = next_carried(carried, stepped)
    end
    context = carried_context(context, carried)

`carried` is a named tuple `(; subcontext = (; field = value, ...), ...)`; its type says which fields it holds. How
those fields are found is hidden in `create_carried` (Writes.jl).
=#

"""
    create_carried(algo, cursor, context, runtimecontext, wiring, namespace, process, lifetime)

What a loop that runs `_step!` with these arguments carries before its first step: the values in `context` of the
fields the step can write, as `(; subcontext = (; field = value, ...), ...)` (all fields when those are not known).
"""
@inline function create_carried(algo::A, cursor::S, context::C, runtimecontext::RC, wiring::W, namespace::N,
                                process::P, lifetime::LT) where {A,S,C<:ProcessContext,RC,W,N,P,LT}
    settled = @inline _runtime_fixed_point(algo, cursor, context, RC, wiring, namespace, process, lifetime)
    return @inline _written_values(context, (@inline _writes(algo, cursor, context, settled, wiring, namespace, process, lifetime)))
end

"""The context with the carried values: what a step gets, and the context after the last step."""
@inline carried_context(context::C, carried::T) where {C<:ProcessContext,T<:NamedTuple} =
    @inline merge_into_subcontexts(context, carried)

"""What a loop carries after a step that returned `stepped`: the new values of the fields `carried` holds."""
@inline next_carried(carried::T, stepped::C) where {T<:NamedTuple,C<:ProcessContext} =
    @inline _written_values(stepped, _carried_fields(T))

"""The `(subcontext, field)` pairs a carried named tuple type holds, as `Val(W)`."""
@generated function _carried_fields(::Type{T}) where {T<:NamedTuple}
    W = Tuple((s, f) for (s, S) in zip(fieldnames(T), fieldtypes(T)) for f in fieldnames(S))
    return :(Val($W))
end

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
