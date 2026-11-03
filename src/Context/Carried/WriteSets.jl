#=
Write sets: the `(subcontext, field)` pairs a step can write, as `Val(written)` (a sorted tuple without repeats), and how
they are built and combined.
=#

"""`written` and `new` as one sorted tuple of `(subcontext, field)` pairs without repeats."""
_union_written(written::Tuple, new::Tuple) = Tuple(sort!(unique!(Any[written..., new...]); by = string))

"""Every `(subcontext, field)` pair of the persistent context type, as `Val(written)`."""
@generated function _every_field(::Type{PersistentContextType}) where {PersistentContextType<:ProcessContext}
    subcontexts = PersistentContextType.parameters[1]
    written = Tuple{Symbol, Symbol}[]
    for s in fieldnames(subcontexts), f in fieldnames(getdatatype(fieldtype(subcontexts, s)))
        push!(written, (s, f))
    end
    return :(Val($(_union_written((), Tuple(written)))))
end

"""The union of two write sets."""
@generated _merge_writable_fields(::Val{A}, ::Val{B}) where {A,B} = :(Val($(_union_written(A, B))))

"""
The write set read off the type `payload_type` of a payload `(; subcontext = (; field = value, ...), ...)`, for every
type in a `Union`; every field of the persistent context type when `payload_type` is not such a named tuple type (for
example when inference cannot tell).
"""
Base.@assume_effects :foldable function _read_payload_fields(@nospecialize(payload_type), @nospecialize(PersistentContextType))
    payload_type === Union{} && return _every_field(PersistentContextType)
    written = ()
    for T in Base.uniontypes(payload_type)
        (T isa DataType && T <: NamedTuple) || return _every_field(PersistentContextType)
        for (subcontext, S) in zip(fieldnames(T), fieldtypes(T))
            (S isa DataType && S <: NamedTuple) || return _every_field(PersistentContextType)
            written = _union_written(written, Tuple((subcontext, field) for field in fieldnames(S)))
        end
    end
    return Val(written)
end
