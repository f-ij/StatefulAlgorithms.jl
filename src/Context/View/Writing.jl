#=
Writing a stored value: every write starts as a `StoreInto` request. Ask the hook `write_value` (Hooks.jl) what
writing to the value stored there does, and follow its answers until every one ends the write (`DirectWrite`,
`NoWrite`). The answers form a tuple that can grow (an answer may be a tuple of actions); the `DirectWrite`s left at
the end are the merge payload.
=#

"""
    _follow_writes(view, requests::Tuple) -> Tuple

Return the `DirectWrite`s that the write actions `requests` end in: each `StoreInto` is answered by
`write_value` and its answers followed in turn; a `NoWrite` ends with nothing.
"""
@inline _follow_writes(view::V, ::Tuple{}) where {V<:SubContextView} = ()
@inline _follow_writes(view::V, actions::A) where {V<:SubContextView, A<:Tuple} =
    ((@inline _follow_write(view, first(actions)))..., (@inline _follow_writes(view, Base.tail(actions)))...)

@inline _follow_write(view::V, action::DirectWrite) where {V<:SubContextView} = (action,)
@inline _follow_write(view::V, ::NoWrite) where {V<:SubContextView} = ()
@inline _follow_write(view::V, request::StoreInto{L}) where {V<:SubContextView, L} =
    @inline _follow_store(view, (@inline stored_value_at(view, L())), request)

# The recursion goes through the stored value, as reads do (`_follow_reads`): it gets simpler at each step of a redirect
# chain (a marker, then the value), so Julia's inference follows it; recursing on the request alone (`StoreInto{L1}`,
# then `StoreInto{L2}`, the same shape) is widened and loses the payload's type.
@inline _follow_store(view::V, stored::S, request::R) where {V<:SubContextView, S, R<:StoreInto} =
    @inline _follow_answer(view, write_value(view, stored, request))

@inline _follow_answer(view::V, action::DirectWrite) where {V<:SubContextView} = (action,)
@inline _follow_answer(view::V, ::NoWrite) where {V<:SubContextView} = ()
@inline _follow_answer(view::V, request::StoreInto{L}) where {V<:SubContextView, L} =
    @inline _follow_store(view, (@inline stored_value_at(view, L())), request)
@inline _follow_answer(view::V, actions::A) where {V<:SubContextView, A<:Tuple} = @inline _follow_writes(view, actions)

"""
    _build_write_payload(writes::Tuple)

Return what the `DirectWrite`s `writes` merge into the persistent context, as `(; subcontext = (; field = value, ...),
...)`, grouped by their locations. Two writes to the same field are an error when the code is generated.
"""
@inline @generated function _build_write_payload(writes::W) where {W<:Tuple}
    names = Symbol[]
    fields = Vector{Expr}[]
    for (i, Write) in enumerate(W.parameters)
        Write <: DirectWrite || error("A write ended in $(Write), which is not a `DirectWrite`.")
        location = Write.parameters[1]
        subcontext, field = get_subcontextname(location), location_fieldname(location)
        k = findfirst(==(subcontext), names)
        k === nothing && (push!(names, subcontext); push!(fields, Expr[]); k = length(names))
        any(ex -> ex.args[1] === field, fields[k]) && error("Two writes in one merge end at `$(subcontext).$(field)` (through a redirect or a share). Write it once.")
        push!(fields[k], Expr(:(=), field, :(getfield(getfield(writes, $i), :value))))
    end
    return Expr(:tuple, Expr(:parameters, (Expr(:(=), names[k], Expr(:tuple, Expr(:parameters, fields[k]...))) for k in eachindex(names))...))
end
