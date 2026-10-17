#=
What a loop carries from one step to the next: only the fields of the persistent context that its steps can write.

The loop keeps two contexts: the persistent context (`persistent_context`) and the runtime context
(`runtime_context`). The runtime context is carried whole. Of the persistent context, the loop carries only the fields
some step can write (`carried`, a named tuple `(; subcontext = (; field = value, ...), ...)`), and reads every other
field from `persistent_context`, which it never reassigns inside the loop:

    carried = create_carried(...the _step! arguments...)
    for ...
        stepped_lc = _step!(..., LoopContext(with_carried(persistent_context, carried), runtime_context), ...)
        stepped_persistent_context, runtime_context = getpersistent(stepped_lc), getruntime(stepped_lc)
        carried = next_carried(carried, stepped_persistent_context)
    end
    persistent_context = with_carried(persistent_context, carried)

Why: if the loop reassigned the whole persistent context every step, every field would be a loop variable, also the
ones no step writes (their new value is their old one). For a context that holds both pointers and plain values,
Julia keeps such a variable in a stack slot and copies it every step, and cannot keep it in registers. The
InteractiveIsing 3D graph example copied 600 + 624 bytes per step and ran at 206 updates/s/spin; carrying only the
written fields: 509.

Which fields a step can write is worked out from the plan's types in Writes.jl (`_find_writable_fields`); `create_carried` asks it.
=#

"""
    create_carried(algo, cursor, lc, wiring, namespace, process, lifetime)

What a loop that runs `_step!` with these arguments carries before its first step: the values, in the persistent
context of `lc`, of the fields the step can write, as `(; subcontext = (; field = value, ...), ...)` (every field when
those are not known).
"""
@inline function create_carried(algo::AlgoType, cursor::CursorType, lc::LoopContext{PersistentContextType, RuntimeContextType}, wiring::WiringViewType, namespace::NamespaceType,
                                process::ProcessType, lifetime::LifetimeType) where {AlgoType, CursorType, PersistentContextType<:ProcessContext, RuntimeContextType, WiringViewType, NamespaceType, ProcessType, LifetimeType}
    persistent_context = @inline getpersistent(lc)
    # The views, and so the writes, depend on the runtime context type. Every repeat sees the same one: a step removes
    # what it adds to the runtime context (a return lives until the end of its block), so its type at the end of a step
    # is its type at the start.
    written = @inline _find_writable_fields(algo, cursor, persistent_context, RuntimeContextType, wiring, namespace, process, lifetime)
    return @inline _written_values(persistent_context, written)
end

"""The persistent context with the carried values put in: what a step gets, and the persistent context after the last step."""
@inline with_carried(persistent_context::PersistentContextType, carried::CarriedType) where {PersistentContextType<:ProcessContext, CarriedType<:NamedTuple} =
    @inline merge_into_subcontexts(persistent_context, carried)

"""What a loop carries after a step: the values, in the persistent context the step returned, of the fields `carried` holds."""
@inline next_carried(carried::CarriedType, stepped_persistent_context::PersistentContextType) where {CarriedType<:NamedTuple, PersistentContextType<:ProcessContext} =
    @inline _written_values(stepped_persistent_context, _carried_fields(CarriedType))

"""The `(subcontext, field)` pairs a carried named tuple type holds, as `Val(written)`."""
@generated function _carried_fields(::Type{CarriedType}) where {CarriedType<:NamedTuple}
    written = Tuple((s, f) for (s, S) in zip(fieldnames(CarriedType), fieldtypes(CarriedType)) for f in fieldnames(S))
    return :(Val($written))
end

"""
    _written_values(persistent_context, Val(written))

The values of the fields `written` (`(subcontext, field)` pairs) in `persistent_context`, as
`(; subcontext = (; field = value, ...), ...)`: the shape `merge_into_subcontexts` takes.
"""
@inline @generated function _written_values(persistent_context::ProcessContext, ::Val{written}) where {written}
    subs = Tuple(unique(first.(written)))
    entries = map(subs) do s
        fields = Tuple(f for (s2, f) in written if s2 === s)
        values = [:(getfield(getdata(getfield(subcontexts, $(QuoteNode(s)))), $(QuoteNode(f)))) for f in fields]
        :(NamedTuple{$fields}(($(values...),)))
    end
    return quote
        subcontexts = @inline get_subcontexts(persistent_context)
        return NamedTuple{$subs}(($(entries...),))
    end
end
