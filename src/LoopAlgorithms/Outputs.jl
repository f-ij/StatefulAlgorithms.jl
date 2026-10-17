#=
Removing a plan node's returns when it ends.

A run holds, next to the stored state: inputs (read-only), declared locals and returns (captured returns, what
statements and calls return, and subcontext returns, what an algorithm returns that is not its state). A return exists
from the line that writes it to the end of its plan node (`leave_scope` removes it, `_strip_returns`), so a step ends
with the runtime context it started with.
=#

"""The type a declared local's `Maybe` holds (the type itself for a value that is not a `Maybe`)."""
_unwrap_slot_type(::Type{T}) where {T} = T
_unwrap_slot_type(::Type{<:Maybe{T}}) where {T} = T

"""The body of `_merge_slots` for named tuple types `NT` and `A`."""
# Loops, not closures: a closure over a type is compiled again for every type.
function _merge_slots_expr(@nospecialize(NT::Type), @nospecialize(A::Type))
    names = Symbol[fieldnames(NT)...]
    for n in fieldnames(A)
        n in fieldnames(NT) || push!(names, n)
    end
    values = Any[]
    for name in names
        if !(name in fieldnames(A))
            push!(values, :(getfield(old, $(QuoteNode(name)))))
        elseif name in fieldnames(NT) && fieldtype(NT, name) <: Maybe && fieldtype(A, name) <: _unwrap_slot_type(fieldtype(NT, name))
            push!(values, :($(fieldtype(NT, name))(getfield(args, $(QuoteNode(name))))))
        else
            push!(values, :(getfield(args, $(QuoteNode(name)))))
        end
    end
    return :(NamedTuple{$(Tuple(names))}(($(values...),)))
end

"""
`merge(old, args)`, except that a value written to a declared local held in a `Maybe` (a local declared with a type
but no value, Locals.jl) is put into it, so the field keeps its type and the runtime context has the same type in every step. A value that does
not fit replaces the field as `merge` does.
"""
@inline @generated _merge_slots(old::NT, args::A) where {NT<:NamedTuple, A<:NamedTuple} = _merge_slots_expr(NT, A)

"""
    _strip_returns(runtime_context, Val(resets))

`runtime_context` without the returns in `resets` (`(; returns, owners)`, see `node_resets`): the captured returns named
in `returns`, and every subcontext return of the namespaces in `owners`. What a plan node leaves behind when it ends.
"""
@inline @generated function _strip_returns(runtime_context::RuntimeContextType, ::Val{Resets}) where {RuntimeContextType<:ProcessContext, Resets}
    Resets isa NamedTuple || return :runtime_context      # outside every node: nothing to strip
    subcontexts = fieldtype(RuntimeContextType, :subcontexts)
    names, values = Symbol[], Any[]
    for (name, S) in zip(fieldnames(subcontexts), fieldtypes(subcontexts))
        source = :(getfield(get_subcontexts(runtime_context), $(QuoteNode(name))))
        removed = name === :_captured_returns ? Resets.returns : name === :_subcontext_returns ? Resets.owners : ()
        data = getdatatype(S)
        kept = Tuple(n for n in fieldnames(data) if !(n in removed))
        if length(kept) == fieldcount(data)
            push!(names, name); push!(values, source)
        elseif !isempty(kept)          # a part left empty is removed, so the type is the one before the node
            fields = [:(getfield(getdata($source), $(QuoteNode(n)))) for n in kept]
            push!(names, name); push!(values, :(SubContext{$(QuoteNode(name))}(NamedTuple{$kept}(($(fields...),)))))
        end
    end
    length(names) == fieldcount(subcontexts) && all(v -> v isa Expr && v.args[1] === :getfield, values) && return :runtime_context
    return :(ProcessContext(NamedTuple{$(Tuple(names))}(($(values...),)), getfield(runtime_context, :reg)))
end
