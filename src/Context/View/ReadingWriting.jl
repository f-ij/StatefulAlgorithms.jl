#=
The machinery that follows the hooks' answers (Hooks.jl): reading a stored value follows `read_value`, writing one
follows `write_value`. The hooks only answer; the recursion is here.
=#

##########################################
########## Reading #######################
##########################################

# Reading a stored value: ask the hook `read_value` (Hooks.jl) what reading it does, and follow its answers until one
# ends the read (`DirectRead`).

"""
    _follow_reads(reader, stored)

Return the value `reader` sees for the value `stored` in one of its fields: the hook `read_value(reader, stored)` is
asked, and its answers are followed until one is a `DirectRead`.
"""
@inline _follow_reads(reader::R, stored::S) where {R<:AbstractContext, S} =
    @inline _follow_read(reader, read_value(reader, stored))

@inline _follow_read(reader::R, action::DirectRead{T}) where {R<:AbstractContext, T} = getfield(action, :value)

# The value stored at `L` is asked about in turn, so a redirect to a redirect is followed as well.
@inline _follow_read(reader::R, ::ReadFrom{L}) where {R<:AbstractContext, L} = @inline _follow_reads(reader, (@inline stored_value_at(reader, L())))

# Unused API for now (see `ReadVar`): no wrapper in the package answers it.
@inline _follow_read(reader::R, action::ReadVar{T}) where {R<:AbstractContext, T} =
    @inline _follow_reads(reader, getfield(action, :value))

"""
    stored_value_at(reader, location)

Return the value stored at the state location `location` (a `VarLocation{:state}`), as it is stored: no hook is asked
about it. What a `ReadFrom` and a `StoreInto` go on with. A view reads it with `partition_storedproperty`, a
`ProcessContext` from its subcontext.
"""
function stored_value_at end

##########################################
########## Writing #######################
##########################################

# Writing a stored value: every write starts as a `StoreInto` request. Ask the hook `write_value` (Hooks.jl) what
# writing to the value stored there does, and follow its answers until every one ends the write (`DirectWrite`,
# `NoWrite`). The answers form a tuple that can grow (an answer may be a tuple of actions); the `DirectWrite`s left at
# the end are the merge payload.

"""
    _follow_writes(view, requests::Tuple) -> Tuple

Return the `DirectWrite`s and `AfterMerge`s that the write actions `requests` end in: each `StoreInto` is answered by
`write_value` and its answers followed in turn; a `NoWrite` ends with nothing.
"""
@inline _follow_writes(view::V, ::Tuple{}) where {V<:SubContextView} = ()
@inline _follow_writes(view::V, actions::A) where {V<:SubContextView, A<:Tuple} =
    ((@inline _follow_write(view, first(actions)))..., (@inline _follow_writes(view, Base.tail(actions)))...)

@inline _follow_write(view::V, action::DirectWrite) where {V<:SubContextView} = (action,)
@inline _follow_write(view::V, action::AfterMerge) where {V<:SubContextView} = (action,)
@inline _follow_write(view::V, ::NoWrite) where {V<:SubContextView} = ()
@inline _follow_write(view::V, request::StoreInto{L}) where {V<:SubContextView, L} =
    @inline _follow_store(view, (@inline stored_value_at(view, L())), request)

# The recursion goes through the stored value, as reads do (`_follow_reads`): it gets simpler at each step of a redirect
# chain (a marker, then the value), so Julia's inference follows it; recursing on the request alone (`StoreInto{L1}`,
# then `StoreInto{L2}`, the same shape) is widened and loses the payload's type.
@inline _follow_store(view::V, stored::S, request::R) where {V<:SubContextView, S, R<:StoreInto} =
    @inline _follow_answer(view, write_value(view, stored, request))

@inline _follow_answer(view::V, action::DirectWrite) where {V<:SubContextView} = (action,)
@inline _follow_answer(view::V, action::AfterMerge) where {V<:SubContextView} = (action,)
@inline _follow_answer(view::V, ::NoWrite) where {V<:SubContextView} = ()
@inline _follow_answer(view::V, request::StoreInto{L}) where {V<:SubContextView, L} =
    @inline _follow_store(view, (@inline stored_value_at(view, L())), request)
@inline _follow_answer(view::V, actions::A) where {V<:SubContextView, A<:Tuple} = @inline _follow_writes(view, actions)

"""
    _build_write_payload(writes::Tuple)

Return what the `DirectWrite`s in `writes` merge into the persistent context, as `(; subcontext = (; field = value, ...),
...)`, grouped by their locations; its `AfterMerge`s are left out (see `_run_after_merge`). Two writes to the same field
are an error when the code is generated.
"""
@inline @generated function _build_write_payload(writes::W) where {W<:Tuple}
    names = Symbol[]
    fields = Vector{Expr}[]
    for (i, Write) in enumerate(W.parameters)
        Write <: AfterMerge && continue
        Write <: DirectWrite || error("A write ended in $(Write), which is not a `DirectWrite` or an `AfterMerge`.")
        location = Write.parameters[1]
        subcontext, field = get_subcontextname(location), location_fieldname(location)
        k = findfirst(==(subcontext), names)
        k === nothing && (push!(names, subcontext); push!(fields, Expr[]); k = length(names))
        any(ex -> ex.args[1] === field, fields[k]) && error("Two writes in one merge end at `$(subcontext).$(field)` (through a redirect or a share). Write it once.")
        push!(fields[k], Expr(:(=), field, :(getfield(getfield(writes, $i), :value))))
    end
    return Expr(:tuple, Expr(:parameters, (Expr(:(=), names[k], Expr(:tuple, Expr(:parameters, fields[k]...))) for k in eachindex(names))...))
end

"""
    _run_after_merge(actions::Tuple)

Run the `AfterMerge`s in the write actions `actions`, in order, once their merge is done: `f(args...)` for each.
"""
@inline _run_after_merge(::Tuple{}) = nothing
@inline function _run_after_merge(actions::A) where {A<:Tuple}
    @inline _run_after_merge(first(actions))
    return @inline _run_after_merge(Base.tail(actions))
end
@inline _run_after_merge(action::AfterMerge) = (getfield(action, :f)(getfield(action, :args)...); nothing)
@inline _run_after_merge(::DirectWrite) = nothing
