#=
Removing a plan node's returns when it ends.

A run holds, next to the stored state: inputs (read-only), declared locals and returns (captured returns, what
statements and calls return, and subcontext returns, what an algorithm returns that is not its state). A return exists
from the line that writes it to the end of its plan node (`leave_scope` removes it, `_strip_returns`), so a step ends
with the runtime context it started with.
=#

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
