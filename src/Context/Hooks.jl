#=
The extendable base of a run's context: which partition (ContextPartitions.jl) something refers to or is read from
(`context_partition`).

Extended in View/HookExtensions.jl (`VarLocation`: the partition it is stored in).
=#

"""
    context_partition(x)

Return the partition of a run's context (`StatePartition{name}()` or `RuntimePartition{name}()`) that `x` refers to or
is read from. For a subcontext name: a namespace's state, unless the name is one of the runtime context's four
partitions. This method is the only place that knows those names.
"""
Base.@constprop :aggressive function context_partition(name::Symbol)
    name === :_captured_returns && return RuntimePartition{:_captured_returns}()
    name === :_subcontext_returns && return RuntimePartition{:_subcontext_returns}()
    name === :_declared_locals && return RuntimePartition{:_declared_locals}()
    name === :_inputs && return RuntimePartition{:_inputs}()
    return StatePartition{name}()
end
